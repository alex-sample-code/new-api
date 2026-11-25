# Linxi AI customizations

This branch (`linxi`) carries the Linxi AI (linxi.ai) branding on top of upstream
`QuantumNous/new-api`. Base: `v1.0.0-rc.51`. `main` mirrors upstream.

## What differs from upstream

| Area | Files |
|---|---|
| Default system name `Linxi AI` | `common/constants.go`, `web/src/lib/constants.ts`, `web/src/components/layout/components/system-brand.tsx`, `web/src/features/system-settings/site/index.tsx`, `web/index.html` |
| Logo / favicon | `web/public/logo.svg`, `logo.png`, `favicon.ico`, `web/src/assets/logo.tsx` |
| Brand palette (indigo → cyan) | `web/src/styles/theme.css`, `web/src/features/home/components/**` |
| Footer: upstream attribution and project link columns removed | `web/src/components/layout/components/footer.tsx` |
| About page empty state: upstream repo/licence block removed | `web/src/features/about/index.tsx` |
| Error page: GitHub issue link removed | `web/src/features/errors/general-error.tsx` |
| Docs link: no default; nav item and hero button hidden until one is set | `setting/operation_setting/general_setting.go`, `web/src/hooks/use-top-nav-links.ts`, `web/src/features/home/components/sections/hero.tsx` |
| Landing copy and self-references in UI text | `web/src/i18n/locales/*.json` (values only, keys unchanged), `web/src/features/home/components/sections/features.tsx` |
| Outbound app name (OpenRouter title/referer, Waffo, chat-app deep links) | `relay/channel/openai/adaptor.go`, `controller/topup_waffo.go`, `web/src/features/chat/lib/chat-links.ts` |

## Deliberately left as upstream

- Go module path, cookie/cache/storage key names, `X-New-Api-Version` response header and the
  `new_api_error` error type (protocol level, not UI).
- Admin-only screens: the "New API" upstream channel type, the plugin marketplace
  (newapi.ai) and the update checker (upstream GitHub releases).
- Source licence headers, `LICENSE`, `NOTICE`.

## Upgrading

```bash
git fetch upstream --tags
git checkout linxi && git merge <new-upstream-tag>
```

Conflicts are expected only in the files listed above.

## Build

```bash
git describe --tags > VERSION && docker build -t linxi-api:$(cat VERSION) . ; git checkout VERSION
```
