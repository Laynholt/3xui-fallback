import crypto from 'crypto';

function under(path, prefix) {
    return path === prefix || path.indexOf(prefix + '/') === 0;
}

function event(r) {
    const v = r.variables;
    let path = (v.request_uri || '/').split(/[?#]/, 1)[0];
    try { path = decodeURIComponent(path); } catch (_) { path = '/_other'; }
    const route = under(path, v.swatter_panel_prefix) ? 'panel' :
        under(path, v.swatter_subs_prefix) ? 'subscription' : 'public';
    const sensitive = path.match(/\/(\.env|\.git\/config|wp-login\.php|xmlrpc\.php)$/);
    // Hash redacted routes: subscription IDs and hidden prefixes are never digest inputs.
    const safe = sensitive ? '/' + sensitive[1] :
        route === 'panel' ? '/_panel' : route === 'subscription' ? '/_subscription' : path;
    const method = (v.request || '').match(/^(GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS|CONNECT) /);
    const status = /^[1-5][0-9][0-9]$/.test(v.status) ? Number(v.status) : 0;
    return JSON.stringify({schema: 'moskit.http.v1', ts: Number(v.msec),
        peer_ip: v.remote_addr, method: method ? method[1] : 'OTHER',
        uri: sensitive ? safe : route === 'public' ? '/_other' : safe,
        status: status, path_hash: crypto.createHash('sha256').update(safe).digest('hex'),
        route_class: route,
        gate_denied: route === 'panel' && status === 404 &&
            v.uri === '/_swatter_panel_denied.html' && !v.upstream_status});
}

export default {event};
