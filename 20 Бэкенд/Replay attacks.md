---
aliases:
  - Replay attack
  - Capture-replay
  - Защита от повторного воспроизведения
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/криптография
статус: проверено
---

# Replay attacks

## TL;DR

Replay attack повторно предъявляет уже валидное сообщение, credential или подтверждение операции. Подпись, MAC и TLS доказывают целостность и происхождение в своей области, но сами по себе не доказывают **свежесть** и **однократность**. Сервер способен дважды проверить одну и ту же корректную подпись и дважды выполнить эффект.

Защита связывает authenticator с principal, purpose, method, target, body и ограниченным временем, а затем атомарно потребляет уникальный `nonce`/`jti`/sequence number. Для retryable business operation отдельно нужен idempotency key: точный повтор операции возвращает прежний результат, а не создаёт второй эффект. Anti-replay и idempotency решают соседние, но разные задачи.

TLS 1.3 0-RTT требует особой осторожности: действующая спецификация RFC 9846 прямо не гарантирует non-replay ранних данных между соединениями. Неидемпотентные действия либо не принимают в 0-RTT, либо защищают на application layer.

## Область применимости

Заметка покрывает capture-replay по CWE-294 4.20, подписанные HTTP/webhook-запросы, одноразовые подтверждения операций, sender-constrained OAuth tokens и TLS 1.3 early data.

Вне scope остаются проектирование конкретного криптографического алгоритма, password brute force и повтор обычного bearer token после кражи как самостоятельная тема session/token theft. Здесь важен invariant: валидное сообщение не должно давать больше разрешённых эффектов, чем предусмотрено protocol.

## Ментальная модель

Authenticity отвечает:

```text
«эти покрытые байты создал владелец ключа»
```

Freshness и uniqueness добавляют два других утверждения:

```text
«сообщение создано в допустимом временном окне»
«это логическое сообщение ещё не было принято»
```

Без последних проверок сервер видит два неразличимых валидных запроса:

```text
request R + valid signature -> effect E
request R + valid signature -> effect E again
```

Transport retry, malicious replay и duplicated delivery могут выглядеть одинаково. Поэтому protocol заранее выбирает семантику duplicate: reject, вернуть сохранённый результат или безопасно повторить idempotent read.

## Как устроено

### Что нужно связать подписью

HTTP Message Signatures по RFC 9421 позволяют покрывать компоненты сообщения и signature metadata. Application profile обязан определить обязательный набор; возможность подписать поле ещё не означает, что verifier потребовал его.

Для state-changing request обычно связывают:

- key/principal и tenant context;
- `@method`, authority и target URI;
- digest точного body representation;
- content type и protocol version/purpose, если они меняют интерпретацию;
- `created`, ограничивающий возраст, и при необходимости `expires`;
- уникальный `nonce` либо иной message ID.

Если body, method или target не покрыты, захваченный authenticator способен подтвердить другое действие в рамках непокрытой части. Если один ключ используется в нескольких protocols, domain separation (`purpose=webhook-v2`, `purpose=transfer-approval`) не даёт перенести валидное сообщение между ними.

Canonicalization задаёт точные байты. Verifier проверяет ту же representation, которую обработает business logic; повторный parse/re-serialize до проверки способен изменить смысл или создать parser differential.

### Freshness window

`created`/timestamp ограничивает время использования. Сервер проверяет:

```text
not_before <= created <= now + allowed_clock_skew
now - created <= max_age
expires, если profile его требует
```

Timestamp один не предотвращает два предъявления внутри `max_age`. Слишком широкое окно увеличивает replay opportunity, слишком узкое ломает legitimate traffic из-за latency и clock skew. Server-provided challenge/nonce уменьшает зависимость от часов и мешает заранее заготовить proof, но добавляет round trip или protocol state.

Clock synchronization относится к availability, а не к доказательству уникальности. При рассогласовании нельзя «временно выключить» nonce check для чувствительных операций.

### Однократное потребление

Stateful verifier хранит ключ вида:

```text
(issuer_or_key_id, principal, purpose, nonce_hash) -> accepted_at
```

Операция должна быть атомарной `insert-if-absent`. Последовательность «проверили cache, выполнили effect, записали nonce» содержит race: два workers одновременно не видят запись. Для критичного действия consume marker и business commit координируют одной транзакцией или другим механизмом, который не оставляет окно double effect.

TTL replay record не меньше максимального acceptance window с учётом skew и задержки. Иначе ещё формально допустимое сообщение станет «новым» после раннего удаления marker. Размер `nonce` ограничивают, в storage часто кладут hash, а namespace включает principal/purpose. RFC 9449 отдельно предупреждает, что хранение неограниченных `jti` само способно вызвать memory exhaustion.

В распределённом verifier строгая однократность требует shared strongly consistent decision либо partitioned ownership. Независимый cache на каждой replica разрешает один replay на replica. Если допустим bounded duplicate, это фиксируют как contract, а не получают случайно.

### Nonce, sequence number и challenge

Random nonce удобен для параллельных независимых запросов. Verifier хранит seen set. Требуется достаточно непредсказуемое/уникальное значение и ограничение размера.

Monotonic sequence number хранит `last_seen` и отвергает старые значения. State меньше, но concurrent/out-of-order delivery, несколько devices и recovery требуют window или отдельных sequence spaces. Если принять `N+100`, что делать с задержавшимся `N+1`, решает protocol.

Server challenge лучше доказывает свежесть: сервер выпускает nonce, client связывает с ним точную операцию, сервер атомарно потребляет challenge. Цена — state и дополнительный обмен. Для high-value transaction это часто оправдано.

### Anti-replay и idempotency

[[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|Idempotency key]] обозначает логическую операцию. При повторе с тем же principal, endpoint и request fingerprint сервер возвращает прежний result; тот же key с другим payload получает conflict. Это сохраняет retry UX при потере ответа.

Anti-replay message ID обозначает конкретное authenticated message. Повтор exact message обычно отвергается. Legitimate retry создаёт новый authenticator/nonce, но сохраняет business idempotency key.

Ни один механизм не заменяет другой:

- nonce без idempotency key может отвергнуть потерянный-response retry, если client повторил exact request, или создать второй effect, если client подпишет retry с новым nonce;
- idempotency key без authentication/replay binding может быть подменён, иметь слишком узкий scope или исчезнуть раньше окна атаки;
- idempotency response не всегда безопасно возвращать любому предъявителю key: сначала повторно проверяется principal и authorization.

### DPoP и sender-constrained tokens

RFC 9449 связывает OAuth access token с client public key и требует уникальный DPoP proof для каждого HTTP request. Proof содержит `jti`, `htm`, `htu`, `iat`, а при resource access — hash access token `ath`. Это мешает использовать украденный token без private key.

Но захваченный DPoP proof можно повторить на том же method/URI в его временном окне. RFC 9449 рекомендует короткий срок и хранение `jti`; строгая single-use проверка требует shared state. Server-provided DPoP nonce дополнительно ограничивает pre-generation. Proof of possession сужает attacker capability, но не отменяет replay state.

### TLS 1.3 0-RTT

Обычные TLS 1.3 application data после handshake получают replay protection внутри protocol connection context. Для 0-RTT RFC 9846 указывает более слабые свойства и отсутствие гарантии non-replay между соединениями. Server-side anti-replay TLS layer уменьшает риск, но в distributed deployment тоже требует coordination и имеет ограничения.

Application endpoint, принимающий early data, проектируют так, будто request может прийти повторно. Безопасные варианты:

- разрешать только операции с действительно safe/idempotent semantics;
- откладывать state-changing effect до завершения 1-RTT;
- использовать application nonce/idempotency transaction, если early data всё же нужна.

Название HTTP method не спасает endpoint, который нарушает семантику и меняет state через `GET`.

## Сквозной пример: retry после потерянного ответа

Client создаёт перевод с business idempotency key `op-73`.

Первое сообщение:

```text
principal = client-9
method    = POST
target    = /v1/transfers
body_hash = h1
op_key    = op-73
nonce     = n-101
created   = T
signature = Sign(all fields above)
```

1. Verifier проверяет key, signature coverage и `created`. В одной транзакции вставляет `(client-9, transfer-v1, hash(n-101))` с unique constraint, создаёт transfer `tr-55` и сохраняет `(client-9, op-73, h1) -> tr-55`.
2. Ответ теряется в сети. Эффект уже committed.
3. Exact capture первого сообщения снова приходит с `n-101`. Unique insert не проходит; verifier отвечает `replay_detected` и не доходит до business effect.
4. Legitimate client делает retry: сохраняет `op-73` и body `h1`, но выпускает fresh signed message с `nonce=n-102` и новым `created`. Anti-replay принимает сообщение. Idempotency lookup находит `tr-55` и возвращает сохранённый result без второго transfer.
5. Если с `op-73` приходит другой `body_hash`, сервер возвращает conflict и не переиспользует result.

Наблюдаемый результат: exact authenticated message принимается один раз, а одна business operation даёт один effect даже при новом корректно подписанном retry. Два independent invariants закрывают разные гонки.

## Trade-offs и альтернативы

### Seen-set или sequence number

Seen-set поддерживает concurrency и out-of-order delivery, но расходует storage пропорционально сообщениям в окне. Sequence number хранит мало state, зато требует упорядочивания, recovery и отдельных counters для независимых senders. Выбор следует из delivery model, а не из удобства поля.

### Client timestamp или server nonce

Timestamp не добавляет round trip и хорошо подходит webhook delivery, но требует clock policy и seen IDs. Server nonce лучше контролирует freshness и pre-generation, однако создаёт state/round trip. Для платежного подтверждения цена приемлема; для high-throughput telemetry чаще используют timestamp + unique event ID.

### Strong global store или bounded replay

Strong shared check даёт строгую single-use семантику, но добавляет latency и availability dependency. Sharded ownership снижает coordination, если nonce deterministically маршрутизируется к одному owner. Локальные caches быстрее, но contract допускает duplicate across replicas; для financial effect это обычно неприемлемо.

### Reject duplicate или вернуть cached result

Security proof/message duplicate логично отвергать. Business retry удобнее завершать сохранённым результатом. Возврат result требует повторной AuthN/AuthZ и аккуратной redaction, иначе idempotency endpoint превращается в oracle.

### Bearer или sender-constrained token

Bearer проще и совместимее, но захват значения даёт capability. DPoP/mTLS связывают token с ключом и уменьшают reuse на чужом устройстве; появляются key lifecycle, proof validation и replay state. Это trade-off масштаба кражи, а не повод убрать short lifetimes и аудит.

## Типичные ошибки

### Проверяют только подпись

- **Неверное предположение:** валидная signature означает новый request.
- **Симптом:** одинаковый signed webhook или command выполняется несколько раз.
- **Причина:** криптография подтверждает покрытые bytes, но verifier не хранит freshness/uniqueness state.
- **Исправление:** обязательные time bounds и atomic nonce/event ID consumption.

### Timestamp считают уникальностью

- **Неверное предположение:** request нельзя повторить в течение пяти минут.
- **Симптом:** несколько effects возникают внутри допустимого clock window.
- **Причина:** один timestamp проходит проверку сколько угодно раз.
- **Исправление:** сочетать time window с `nonce`/`jti`/event ID seen-set.

### Nonce записывают после effect

- **Неверное предположение:** два одинаковых запроса не выполняются одновременно.
- **Симптом:** rare double charge/double enqueue под concurrency.
- **Причина:** check-then-act race между replicas или workers.
- **Исправление:** atomic insert-if-absent и координация consume с business transaction.

### Seen cache локален каждой replica

- **Неверное предположение:** load balancer всегда отправит duplicate туда же.
- **Симптом:** один и тот же proof принимается по разу на нескольких instances.
- **Причина:** replay state не соответствует scope endpoint.
- **Исправление:** shared/partitioned strong decision либо явный bounded-duplicate contract.

### TTL короче acceptance window

- **Неверное предположение:** marker можно удалить сразу после среднего retry time.
- **Симптом:** старое, но ещё допустимое по timestamp сообщение снова принимается.
- **Причина:** uniqueness memory закончилась раньше freshness validity.
- **Исправление:** TTL не меньше полного acceptance window + skew/delivery margin.

### Idempotency key не связан с payload и principal

- **Неверное предположение:** уникальной строки достаточно.
- **Симптом:** другой запрос получает чужой cached result или переиспользует key с новой операцией.
- **Причина:** namespace/fingerprint не входят в invariant.
- **Исправление:** scope `(principal, operation, key)`, сравнение canonical request fingerprint и повторная authorization.

## Когда применять

Anti-replay нужен там, где записанное валидное сообщение сохраняет ценность: webhooks, signed partner API, transaction approval, device command, password reset/verification link и sender-constrained token proof. Для каждого protocol фиксируют покрытые поля, clock/challenge policy, uniqueness scope, атомарность, duplicate response и срок хранения state.

Практическое правило: подпись отвечает «кто и что», timestamp — «когда», nonce/sequence — «впервые ли», idempotency key — «какая логическая операция». Для неидемпотентного эффекта нужны все применимые ответы, а не одно поле с многообещающим названием.

## Источники

- [CWE-294: Authentication Bypass by Capture-replay](https://cwe.mitre.org/data/definitions/294.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [RFC 9421: HTTP Message Signatures](https://datatracker.ietf.org/doc/html/rfc9421) — IETF, RFC 9421, февраль 2024, проверено 2026-07-18.
- [RFC 9449: OAuth 2.0 Demonstrating Proof of Possession](https://datatracker.ietf.org/doc/html/rfc9449) — IETF, RFC 9449, сентябрь 2023, проверено 2026-07-18.
- [RFC 9846: The Transport Layer Security Protocol Version 1.3](https://datatracker.ietf.org/doc/rfc9846/) — IETF, RFC 9846, июль 2026; obsoletes RFC 8446, разделы 2.3 и 8, проверено 2026-07-18.
- [Transaction Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/html/rfc9700) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
