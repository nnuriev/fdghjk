---
aliases:
  - Security in System Design
  - Безопасность архитектуры
tags:
  - область/проектирование-систем
  - тема/безопасность
статус: проверено
---

# Security в System Design

## TL;DR

Security проектируют по assets, actors, trust boundaries и abuse cases. На схеме нужно показать, где аутентифицируется субъект, кто принимает authorization decision, как ограничивается credential, какие данные шифруются и удаляются, где живут secrets и audit trail, как система ведёт себя при компрометации одного компонента.

Edge gateway не делает внутреннюю сеть доверенной. Каждый сервис проверяет audience и полномочия на своём ресурсе, machine identity короткоживущая, permissions минимальны, а высокорисковые операции требуют отдельного policy и неизменяемого audit. Availability-защита от abuse входит в security так же, как confidentiality.

## Ментальная модель

Security boundary отвечает на четыре вопроса:

```text
кто субъект -> что он просит -> кто решает -> какое доказательство остаётся
```

Zero trust в NIST SP 800-207 означает отсутствие неявного доверия только из-за сетевого положения. Это не продукт и не обещание «проверять всё одинаково»: identity, device/workload context и resource policy оцениваются для конкретного доступа.

## Как устроено

### Assets и threat model

Назовите assets: деньги, PII, content, credentials, availability, audit и control plane. Для каждого actor/entry point рассмотрите spoofing, tampering, information disclosure, privilege escalation, replay и resource exhaustion. Отдельно включите malicious tenant, compromised employee/service, dependency и operator mistake.

Threat model приоритизирует controls. Encrypting public thumbnails даёт мало пользы, если pre-signed upload позволяет заменить чужой object.

### Authentication и authorization

Authentication связывает request с user/workload identity. Authorization проверяет action над конкретным resource и tenant. Их API-механика разобрана в [[20 Бэкенд/Аутентификация и авторизация на уровне API|заметке об аутентификации и авторизации]].

Gateway может валидировать token format и coarse policy, но downstream остаётся владельцем object-level decision. Token ограничивают audience, scope, lifetime и sender, где оправдано. RFC 9700 запрещает устаревший resource owner password credentials grant и рекомендует современные защиты OAuth flows.

Service-to-service identity должна переживать rotation без общего долгоживущего secret. mTLS подтверждает peer transport identity, но authorization всё равно проверяет workload, method и resource. Network policy уменьшает blast radius, но не заменяет application policy.

### Data protection

Классифицируйте данные и их lifecycle:

- encryption in transit по TLS и at rest с управляемыми keys;
- tenant/resource authorization на каждом read/write;
- минимизация и purpose limitation;
- retention, legal hold и verifiable deletion;
- backup, replica, cache, log и search-index copies;
- redaction/tokenization для telemetry и analytics.

Ключ шифрования не должен храниться рядом с ciphertext под теми же credentials. Rotation и revoke проверяются, а envelope encryption ограничивает работу root key. Cache key/namespace обязан включать tenant и authorization-relevant variant; private response не попадает в shared public cache.

### Secrets и supply chain

Secrets получают через dedicated secret manager, короткоживущие credentials и least privilege. Они не входят в image, source, logs или user-visible errors. Rotation должна работать без одновременного restart всего fleet.

Артефакт release связывают с reviewed source, reproducible/controlled build, provenance и vulnerability response. Dependency pinning без процедуры обновления лишь замораживает известную уязвимость.

### Abuse и availability

[[20 Бэкенд/Rate limiting и quotas|Rate limiting]] применяется по verified identity, tenant, IP/device signals и cost units. Один request способен запускать дорогой fan-out, поэтому ограничение по request count может быть недостаточно. Нужны concurrency/admission, payload limits, pagination caps, decompression ratio, upload quotas и защита expensive queries.

DDoS absorption располагается на edge/CDN, но application-level abuse виден глубже. Failure mode security dependency выбирают явно: deny-by-default для sensitive mutation; ограниченный cached policy иногда допустим для low-risk read при заданном TTL.

### Audit и response

Audit event отвечает кто/что/когда/над каким resource/с каким outcome и policy version. Он append-only с контролем доступа и retention, не содержит секретов. Business audit не заменяется debug logs: у них разные гарантии полноты и удаления.

План incident response включает revoke credentials, isolate workload, rotate keys, invalidate sessions, preserve evidence, определить затронутые tenants и восстановить из trusted artifact/data.

## Сквозной пример: file/blob service

Пользователь запрашивает upload session для private file.

1. API аутентифицирует user, проверяет право создать object и атомарно резервирует tenant quota на заявленный размер; истёкшая или отменённая session освобождает резерв.
2. Metadata service создаёт `object_id`, ожидаемый size/checksum и короткоживущее upload credential. Например, pre-signed POST policy ограничивает exact key, expiry и `content-length-range`; для другого provider нужен эквивалентный storage-side constraint либо upload proxy, который отклоняет лишние bytes до сохранения объекта.
3. Client загружает bytes напрямую в object storage. Credential не даёт list/read и не позволяет выбрать чужой key или превысить подписанный диапазон размера.
4. Completion API проверяет metadata ownership, фактический size/checksum и переводит object из `UPLOADING` в `SCANNING`.
5. Scanner с отдельной service identity читает quarantine namespace. Только clean immutable version становится `READY`.
6. Download API повторно проверяет authorization и выдаёт короткий read URL; CDN cache отключён для private variant либо key подписан и изолирован.

Failure/attack cases:

- stolen upload credential ограничен expiry, exact key, storage-side size policy и зарезервированной quota;
- zip bomb отсекается до unbounded decompression;
- scanner unavailable не публикует object, но upload может оставаться durable;
- deletion tombstone запускает удаление body, replicas, derived preview и cache; audit хранит факт без содержимого;
- compromised scanner не имеет права менять metadata policy или читать другие buckets.

## Trade-offs

Короткоживущие credentials уменьшают окно компрометации, но зависят от identity control plane и clock. Cached authorization повышает availability, зато продлевает действие отозванного права. TTL выбирают по ущербу и degraded policy.

End-to-end encryption скрывает content от сервера и снижает blast radius, но усложняет search, moderation, server-side processing и recovery. Это продуктовый выбор, а не бесплатный checkbox.

Центральный policy engine упрощает единые правила и audit, но может стать latency/availability dependency. Локальная проверка signed policy bundle сохраняет data plane, однако требует versioning, expiry и safe fallback.

## Типичные ошибки

- **Неверное предположение:** внутренний request доверенный. **Симптом:** SSRF или compromised service читает чужие данные. **Причина:** network location стала authorization. **Исправление:** workload identity, audience и resource policy на owner.
- **Неверное предположение:** gateway полностью закрыл auth. **Симптом:** прямой/internal path обходится без object-level check. **Причина:** coarse edge decision подменил domain authorization. **Исправление:** defense in depth и deny на каждом owner endpoint.
- **Неверное предположение:** encryption at rest решает утечку. **Симптом:** service credential выгружает plaintext всего tenant. **Причина:** key access и application authorization не ограничены. **Исправление:** least privilege, tenant boundaries, audit и scoped keys.
- **Неверное предположение:** логировать весь request полезно для расследования. **Симптом:** tokens и PII попадают в менее защищённую telemetry. **Причина:** observability не классифицирована как data copy. **Исправление:** allowlist fields, redaction и отдельная retention.
- **Неверное предположение:** rate limit по IP блокирует abuse. **Симптом:** один authenticated tenant запускает дорогие fan-out jobs. **Причина:** identity и cost не вошли в unit. **Исправление:** tenant/user quotas, cost units и concurrency caps.

## Когда применять

Threat model строят вместе с первой архитектурной схемой и обновляют при новом data flow, tenant, provider или control plane. Security review считается содержательным, когда controls привязаны к угрозе, имеют owner/telemetry и проверенный failure behavior.

## Источники

- [NIST SP 800-207: Zero Trust Architecture](https://csrc.nist.gov/pubs/sp/800/207/final) — NIST, SP 800-207, август 2020, проверено 2026-07-18.
- [OWASP Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/) — OWASP Foundation, ASVS 5.0.0 от 2025-05-30, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/html/rfc9700) — IETF, RFC 9700 / BCP 240, январь 2025, проверено 2026-07-18.
- [RFC 8446: The Transport Layer Security Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446) — IETF, RFC 8446, август 2018, проверено 2026-07-18.
- [NIST SP 800-218: Secure Software Development Framework](https://csrc.nist.gov/pubs/sp/800/218/final) — NIST, SSDF 1.1, февраль 2022, проверено 2026-07-18.
- [POST Policy](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-HTTPPOSTConstructPolicy.html) — Amazon Web Services, документация Amazon S3 о POST policy conditions, проверено 2026-07-18.
