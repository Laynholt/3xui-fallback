import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {test} from 'node:test';

const source = readFileSync(new URL('../swatter.js', import.meta.url), 'utf8');
const {default: audit} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const request = (uri, extra = {}) => ({variables: {
    request_uri: uri, request: 'GET ' + uri + ' HTTP/1.1',
    swatter_panel_prefix: '/hidden-panel', swatter_subs_prefix: '/private-subs',
    swatter_host: 'example.test',
    remote_addr: '2001:db8::1', msec: '1000.123', status: '404',
    uri: '/404.html', upstream_status: '', ...extra,
}});
const event = (uri, extra) => JSON.parse(audit.event(request(uri, extra)));
const hash = path => createHash('sha256').update(path).digest('hex');

test('original unknown paths remain distinct across error redirects, with no query', () => {
    const a = event('/probe-a?token=SECRET');
    const b = event('/probe-b');
    assert.equal(a.uri, '/_other');
    assert.equal(a.path_hash, hash('/probe-a'));
    assert.equal(event('/probe-a?changed=query').path_hash, a.path_hash);
    assert.notEqual(a.path_hash, b.path_hash);
    assert.equal(a.route_class, 'public');
    assert.equal(a.gate_denied, false);
    assert.equal(a.peer_ip, '2001:db8::1');
    assert.doesNotMatch(JSON.stringify(a), /SECRET|probe-a|token/);
});

test('known secret prefixes and dynamic subscription IDs are removed before hashing', () => {
    for (const [path, alias, route] of [
        ['/hidden-panel/login?key=SECRET', '/_panel', 'panel'],
        ['/private-subs/SECRET/assets/app.js', '/_subscription', 'subscription'],
        ['/private-subs/OTHER', '/_subscription', 'subscription'],
    ]) {
        const record = event(path);
        assert.equal(record.uri, alias);
        assert.equal(record.path_hash, hash(alias));
        assert.equal(record.route_class, route);
        assert.doesNotMatch(JSON.stringify(record), /hidden-panel|private-subs|SECRET|OTHER/);
    }
    assert.equal(event('/hidden-panel-lookalike').route_class, 'public');
});

test('json prefix paths are classified as subscription', () => {
    for (const path of ['/json/SECRET', '/json/SECRET/assets/app.js']) {
        const record = event(path, {swatter_subs_json_prefix: '/json'});
        assert.equal(record.route_class, 'subscription');
        assert.equal(record.uri, '/_subscription');
        assert.equal(record.path_hash, hash('/_subscription'));
        assert.doesNotMatch(JSON.stringify(record), /SECRET|json/);
    }
    assert.equal(event('/jsonish', {swatter_subs_json_prefix: '/json'}).route_class, 'public');
});

test('empty json prefix matches nothing', () => {
    for (const extra of [{swatter_subs_json_prefix: ''}, {}]) {
        assert.equal(event('/anything', extra).route_class, 'public');
    }
});

test('sensitive labels survive secret prefixes and encoded dotfiles', () => {
    for (const path of ['/private-subs/SECRET/.env?key=SECRET', '/%2eenv']) {
        assert.equal(event(path).uri, '/.env');
        assert.equal(event(path).path_hash, hash('/.env'));
    }
});

test('only local panel access denial is a gate event', () => {
    const marker = {uri: '/_swatter_panel_denied.html'};
    assert.equal(event('/hidden-panel/login', marker).gate_denied, true);
    assert.equal(event('/hidden-panel/login', {...marker, upstream_status: '403'}).gate_denied, false);
    assert.equal(event('/ordinary-404').gate_denied, false);
    assert.equal(event('/hidden-panel/login', {status: '444'}).gate_denied, false);
    assert.equal(event('/_swatter_panel_denied.html').gate_denied, false);
});

test('fixed original methods and strict fields prevent header or redirect leakage', () => {
    const record = event('/.env', {request: 'POST /.env?SECRET HTTP/1.1', request_method: 'GET',
        http_x_forwarded_for: '8.8.8.8', http_authorization: 'SECRET'});
    assert.equal(record.method, 'POST');
    assert.equal(record.peer_ip, '2001:db8::1');
    assert.deepEqual(Object.keys(record).sort(), ['gate_denied','host','method','path_hash','peer_ip','route_class','schema','status','ts','uri']);
    assert.equal(event('/a', {request: 'SECRET /a HTTP/1.1'}).method, 'OTHER');
    assert.equal(event('/a', {status: 'invalid'}).status, 0);
});

test('ambiguous paths collapse before hashing, including encoded separators and dot segments', () => {
    for (const raw of ['/./private-subs/SECRET', '/a/../private-subs/SECRET',
        '//private-subs/SECRET', '/a/%2e%2e/private-subs/SECRET',
        '/%2fprivate-subs/SECRET', '/private-subs/SECRET/../asset', '/bad%xx/SECRET']) {
        const record = event(raw);
        assert.equal(record.path_hash, hash('/_other'), raw);
        assert.equal(record.route_class, 'other', raw);
        assert.equal(record.uri, '/_other');
    }
    for (const raw of ['/./hidden-panel/login', '//hidden-panel/login', '/a/../hidden-panel/login']) {
        const record = event(raw, {uri: '/_swatter_panel_denied.html'});
        assert.equal(record.gate_denied, true);
        assert.equal(record.route_class, 'panel');
        assert.equal(record.path_hash, hash('/_panel'));
    }
});

test('configured trailing prefixes redact descendants and host is fixed and validated', () => {
    for (const [path, key, alias] of [['/private-subs/SECRET', 'swatter_subs_prefix', '/_subscription'],
        ['/hidden-panel/SECRET', 'swatter_panel_prefix', '/_panel']]) {
        const record = event(path, {[key]: key === 'swatter_subs_prefix' ? '/private-subs/' : '/hidden-panel/'});
        assert.equal(record.path_hash, hash(alias));
    }
    assert.equal(event('/a', {http_host: 'attacker.test', host: 'attacker.test'}).host, 'example.test');
    assert.equal(event('/a', {swatter_host: 'EXAMPLE.TEST.'}).host, 'example.test');
    for (const host of ['SECRET@host', 'host/path', 'host?token=SECRET', '-host', '', 'a'.repeat(254)]) {
        assert.equal(event('/a', {swatter_host: host}).host, '');
    }
});
