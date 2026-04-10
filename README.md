# 3xui-fallback

Легковесный nginx-фронт для 3x-ui с кастомными fallback-страницами ошибок и проксированием на два backend-сервиса:

- панель
- подписки

Проект подставляет точечные HTML-страницы для конкретных HTTP-ошибок и отдает их через `proxy_intercept_errors on`, чтобы пользователь видел не стандартную заглушку nginx, а оформленную страницу с понятным описанием проблемы.

## Что внутри

- `docker-compose.yml` для запуска nginx в `host` network
- `nginx.conf` как шаблон, который заполняется через `envsubst`
- `html/` с отдельными страницами для `400`, `401`, `403`, `404`, `405`, `500`, `502`, `503`, `504`
- `html/error-pages.css` с общим стилем и легкой анимацией фона

## Примеры

<p>
  <img src="./docs/screenshots/404.png" alt="404 error page preview" width="49%" />
  <img src="./docs/screenshots/503.png" alt="503 error page preview" width="49%" />
</p>

## Поддерживаемые ошибки

| Код | Значение |
| --- | --- |
| 400 | Bad Request |
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Not Found |
| 405 | Method Not Allowed |
| 500 | Internal Server Error |
| 502 | Bad Gateway |
| 503 | Service Unavailable |
| 504 | Gateway Timeout |

## Как запустить

1. Создайте `.env` на основе `.env.example`.
2. Укажите домен, внешние HTTPS-порты, backend-адреса и пути к SSL-сертификатам.
3. Запустите контейнер:

```bash
docker compose up -d
```

При старте контейнер:

- подставляет переменные окружения в `nginx.conf`
- валидирует итоговую конфигурацию через `nginx -t`
- запускает nginx в foreground-режиме

## Как это работает

В обоих `server`-блоках nginx проксирует трафик на upstream backend и перехватывает ошибки:

```nginx
proxy_intercept_errors on;
error_page 404 /404.html;
error_page 503 /503.html;
```

HTML-файлы лежат в `/usr/share/nginx/html`, а сами error pages доступны только через внутренний редирект nginx. Общий CSS отдается отдельно, чтобы не дублировать стили во всех шаблонах.

## Структура

```text
.
├── docker-compose.yml
├── nginx.conf
├── .env.example
├── html/
│   ├── error-pages.css
│   ├── 400.html
│   ├── 401.html
│   ├── 403.html
│   ├── 404.html
│   ├── 405.html
│   ├── 500.html
│   ├── 502.html
│   ├── 503.html
│   └── 504.html
└── docs/
    └── screenshots/
        ├── 404.png
        └── 503.png
```
