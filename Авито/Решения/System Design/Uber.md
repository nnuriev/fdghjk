---
aliases:
  - Ride-hailing system design
  - Проектирование Uber
  - Taxi backend system design
tags:
  - тип/разбор
  - область/проектирование-систем
  - компания/авито
  - тема/геосервисы
статус: проверено
---

# Uber

## TL;DR

Система разделяется на четыре контура: ingestion координат, latest-location/geo index, transactional trip/dispatch state и immutable trip history. GPS events с device sequence поступают в региональный log; projector обновляет последнюю позицию и H3-cell membership. Nearby search читает соседние cells, отбрасывает stale/занятых водителей, считает точное расстояние и затем ETA по дорожному графу.

Единственного победителя при принятии заказа обеспечивает не push и не distributed lock, а атомарный переход regional assignment store: trip ещё `SEARCHING`, driver ещё `AVAILABLE`, затем оба становятся `ASSIGNED` с новой version/fencing token. Все остальные ответы получают «заказ уже назначен». Offline track догружается идемпотентными segments с sequence; event time, accuracy и физически правдоподобные границы важнее простого усреднения.

Страны имеют независимый data plane и failure domain. Падение DC страны X не затрагивает booking в Y; PII и треки не проходят через обязательную глобальную синхронную зависимость. Это требование независимости, а не обещание, что сама X продолжит работать без отдельного multi-DC дизайна.

## Контекст и ментальная модель

Нужно спроектировать backend ride-hailing:

- пассажир видит доступных водителей рядом;
- заказывает поездку A→B;
- ближайшие водители получают предложение, но принять может только один;
- passenger видит ETA и progress/track;
- история поездок хранит треки;
- обе стороны отправляют координаты каждые 10 секунд;
- система работает в разных странах независимо и переживает offline участки маршрута.

Ключевое разделение: позиция — быстро устаревающее наблюдение, trip — business state с сильными инвариантами, track — append-only history. Нельзя заставлять один geo index одновременно быть источником денег, диспетчеризации и исторического аудита.

## Требования

### Функциональные

- Обновлять location водителя и пассажира с monotonic sequence, включая buffered offline upload.
- Показать nearby available drivers и предварительную ETA/ценовую оценку, если pricing входит в product boundary.
- Создать idempotent trip request A→B и запустить dispatch waves.
- Доставить offer нескольким подходящим drivers; атомарно принять только первый валидный ответ.
- Вести state machine поездки и отдавать passenger progress online.
- Завершить поездку, собрать ordered track и предоставить history.
- Разделить данные и работу стран так, чтобы отказ одной не каскадировал в другую.

### Нефункциональные и SLO

Из условия заданы объём поездок и период location updates, но не SLO. Проектные цели интервью:

- trip create/accept: 99,95% availability, p99 server-side до 700 мс;
- 99% dispatch attempts получают driver или terminal `NO_DRIVER` не позже 15 секунд;
- accepted driver position появляется у passenger не позже 15 секунд при online devices;
- только один driver владеет действующей assignment version;
- acknowledged trip transition переживает отказ availability zone;
- страны не имеют synchronous runtime dependency друг на друга.

GPS не позволяет обещать истинную позицию с точностью до метра: API возвращает `observed_at`, `accuracy` и freshness, а UI умеет показывать stale state.

### Вне scope

- Реализация карт, routing/traffic engine, payment ledger, dynamic pricing и fraud ML.
- Driver onboarding, support и юридические правила конкретной страны.
- Навигация turn-by-turn и точный map matching algorithm.
- Межстрановая поездка и глобальный active-active trip.

## Оценка нагрузки и ёмкости

Вводные: рост со 100k до 1M trips/day, средний пользователь делает одну поездку в день, average duration 15 минут, peak trip 40 минут, driver и passenger посылают location каждые 10 секунд.

На 1M trips/day:

- average trip starts: `1 000 000 / 86 400 ≈ 11,6/s`;
- при принятом для capacity peak factor 10: `≈116 trip starts/s`;
- average concurrent trips по Little's law: `11,6 × 900 s ≈10 417`;
- 15-minute trip: `900/10 = 90` points/device, `180` points/trip;
- `180M location events/day`, average `≈2 083/s`; при peak factor 10 — `≈20,8k/s`;
- 40-minute trip: `2 × 2 400/10 = 480` points.

Это только in-trip telemetry из условия. Для nearby search нужны updates всех online available drivers; их частота не задана. Если `D` drivers online и обновляются каждые 10 секунд, дополнительный ingress — `D/10 events/s`. Именно этот параметр может доминировать и должен быть запрошен.

Если нормализованный track event с IDs, coordinates, times и accuracy занимает в среднем 100 bytes — наше planning assumption — 180M events дают около `18 GB/day` logical до encoding, indexes и replicas. Raw JSON обычно больше; compact columnar archive меньше. Retention и legal locality не заданы, поэтому годовой объём без них считать преждевременно.

## API и модель данных

### API

```http
POST /v1/location-batches
{"device_id":"d1","points":[{"seq":481,"observed_at":"...","lat":...,"lon":...,"accuracy_m":12}]}

GET /v1/drivers/nearby?lat=...&lon=...&radius_m=3000&limit=20

POST /v1/trips
Idempotency-Key: trip-request-42
{"pickup":{...},"destination":{...}}

PUT /v1/trips/{trip_id}/offers/{offer_id}:accept
If-Match: "offer-version-3"

POST /v1/trips/{trip_id}:start
POST /v1/trips/{trip_id}:complete
GET /v1/trips/{trip_id}
```

Location batch ограничен по points/time span и адресуется `(device_id, seq range)`, поэтому reconnect не создаёт duplicate. Long-lived update passenger получает по WebSocket/SSE; connection не является источником trip state.

### Модель данных

```text
trip(
  country_id, trip_id, rider_id, driver_id,
  pickup, destination, state, version, assignment_epoch,
  created_at, accepted_at, started_at, completed_at
)

driver_availability(
  country_id, driver_id, state, state_version,
  current_trip_id, lease_until
)

dispatch_offer(
  trip_id, offer_id, driver_id, wave, status,
  expires_at, trip_version
)

latest_location(
  country_id, subject_id, subject_type,
  seq, observed_at, received_at, point, accuracy, h3_cell, expires_at
)

location_event(
  country_id, subject_id, seq, observed_at,
  received_at, coordinates, accuracy, trip_id?
)

track_manifest(trip_id, segment_id, seq_from, seq_to, object_ref, checksum)
outbox(event_id, aggregate_id, aggregate_version, payload)
```

Trip state machine:

```text
REQUESTED -> SEARCHING -> ASSIGNED -> DRIVER_ARRIVING
          -> NO_DRIVER             -> IN_PROGRESS -> COMPLETED
                    \-> CANCELLED (только из явно разрешённых состояний)
```

Каждый command передаёт expected version. `assignment_epoch` — fencing token для дальнейших driver commands; late process с прежней epoch не может начать или завершить trip.

## Архитектура и критические потоки

```text
Mobile -> regional edge/location API -> durable event log
                                \-> latest-location projector -> H3 buckets/KV
                                \-> track builder -> object/columnar archive

Rider API -> Trip Service -> regional transactional assignment store -> outbox
                        \-> Dispatch -> geo candidates -> routing/ETA -> Offer service

Trip/location events -> Realtime gateway -> rider/driver devices
Global edge -> country router -> independent country data plane
```

### Location ingestion и nearby

Location API проверяет authentication, coordinate bounds, batch size и monotonic `seq`. Log сохраняет raw event; projector принимает только sequence новее stored. При переходе H3 cell он добавляет driver в новый bucket и удаляет из старого. Поскольку distributed KV operations могут разойтись, bucket entry содержит location version, TTL, а query сверяет candidate с authoritative latest record.

Nearby flow следует [[30 Данные/Геопространственные индексы и поиск ближайших объектов|двухфазной геопространственной модели]]:

1. покрыть radius H3 cells и прочитать buckets;
2. дедуплицировать drivers, отбросить stale location, `state != AVAILABLE` и неверную version;
3. вычислить точное расстояние;
4. для небольшого top-N вызвать routing/ETA, потому что прямая геометрическая близость не учитывает дороги;
5. вернуть position с freshness/accuracy, не обещая availability до reservation.

Hot cells у аэропорта suffix-shard-ятся по hash driver ID или более fine resolution. Query читает bounded число suffixes; adaptive split запускается по candidates/cell и CPU.

### Создание и dispatch

1. Idempotency key создаёт один `trip_id` в home country/region. Trip становится `SEARCHING`; transaction пишет outbox.
2. Dispatcher получает geo candidates и формирует первую wave. Большая одновременная рассылка повышает chance быстрого ответа, но создаёт раздражающие проигравшие offers; waves ограничены.
3. Offer имеет expiry и trip version. Push/WS — лишь доставка приглашения.
4. При accept regional assignment transaction проверяет: trip всё ещё `SEARCHING`, offer valid, driver `AVAILABLE`, lease свежая. Она переводит trip в `ASSIGNED`, driver в `ASSIGNED`, увеличивает versions/epoch и пишет outbox.
5. Конкурентный accept не проходит conditional update и получает terminal `ALREADY_ASSIGNED`.

Trip starts peak порядка сотен в секунду по нашему допущению, поэтому strong regional SQL/consensus-backed KV разумнее сложной distributed lock mesh. Если trip и driver нельзя изменить одной transaction, reservation service должен стать единственным serializing authority; lease без fencing insufficient.

### Progress и offline track

Online projector хранит latest positions и посылает update passenger. Durable track builder группирует ordered points в segments; manifest публикуется после checksum. Offline device хранит batch с original `seq` и monotonic/device timestamps, затем догружает его.

Сервер:

- дедуплицирует по `(device_id, seq)`;
- не переставляет track только по `received_at`;
- отмечает clock uncertainty и accuracy;
- отклоняет физически невозможные jumps либо помечает их для map matching;
- интерполирует gap только между валидными anchors и не выдаёт interpolation за наблюдаемую GPS-точку.

Простое арифметическое «усреднить все coordinates» способно провести маршрут через здания. Для billing/dispute хранят raw points и version алгоритма derived track.

### Изоляция стран

Global edge определяет country из account/trip context и направляет запрос в country data plane. Внутри страны сервисы и stores реплицируются между availability zones; при требовании продолжать X после потери whole DC добавляется второй DC той же legal region с согласованным RPO/RTO.

Country Y не делает synchronous calls в X для booking. Global control plane распространяет config/versions асинхронно и имеет last-known-good cache. Общие identity/fraud dependencies должны иметь regional fallback, иначе формальная раздельность databases не предотвращает cascading failure.

## Масштабирование и надёжность

- Event log partition: `(country_id, hash(subject_id))` сохраняет order одного device и распределяет ingest.
- Trip/assignment: country/metro locality; strong transaction на state transitions. Partition migration использует epochs.
- Latest location: TTL KV + H3 buckets; history не читается из этой projection.
- Track: append segments и compact archive; object storage отделяет дешёвую history от hot state.
- Realtime gateways stateless относительно durable trip; reconnect читает current version/event cursor.
- Routing/ETA имеет timeout, cache и circuit breaker; при сбое можно показать straight-line approximate estimate с явной degraded marker либо не dispatch-ить — решение бизнеса.
- Backpressure: history/archive consumer может отставать; latest-location projector получает приоритет, но raw log retention должен покрывать replay.
- Cross-country quotas не делят один общий pool, чтобы overload X не исчерпал threads/connections Y.

## Failure modes

| Отказ | Обнаружение | Реакция |
| --- | --- | --- |
| Два drivers принимают одновременно | conditional update conflict | один commit получает epoch, остальные `ALREADY_ASSIGNED` |
| Accept response потерян | retry offer ID + expected version | вернуть текущее assignment, не назначать повторно |
| Driver location пришла поздно | sequence меньше stored | сохранить raw при policy, latest projection не откатывать |
| Ghost entry в старой cell | bucket version не совпадает/latest TTL | query отбрасывает; reconciliation удаляет |
| Location stream backlog | event-time lag, stale-driver ratio | autoscale projector; stale drivers исключить из dispatch |
| Driver offline в trip | heartbeat/freshness | не отменять мгновенно; UI показывает stale, device догружает segment |
| Routing service недоступен | timeout/error budget | degraded distance shortlist или controlled dispatch pause |
| Country X overload/DC loss | regional health and saturation | isolate routing/quotas; Y продолжает локально; X следует собственному DR plan |
| Старый dispatcher ожил | stale assignment epoch | все state-changing commands отклоняются fencing check |
| Track segment загружен дважды | same device/seq/checksum | idempotent manifest merge |

## Безопасность

- Coordinates и trip history — чувствительные PII. Data residency, retention, deletion, access audit и purpose limitation определяются per country; техническая модель следует [[20 Бэкенд/Обработка PII|обработке PII]].
- Rider видит только assigned driver и bounded precision до принятия; публичный nearby endpoint не раскрывает stable driver IDs/точные треки.
- Device identity и session привязаны к account; location batch защищён от replay sequence и невозможных временных диапазонов.
- Internal services используют least privilege: dispatch читает latest driver location, но analytics не получает live identity без основания.
- Encryption in transit/at rest, key residency и rotation per region. Logs/traces не содержат raw coordinates.
- Abuse controls: rate limit trip creates/accepts, detect impossible movement, secure driver state transitions, audit manual overrides.
- GDPR — лишь один из возможных правовых regimes; продукт обязан применять требования каждой страны, а не копировать одну policy глобально.

## Observability и SLO

- Trip funnel: create → search → offers → accept → start → complete, latency и terminal reasons.
- Assignment invariant violations, conditional-conflict rate, expired offers, duplicate accept retries.
- Location: events/s, ingest latency by event time, out-of-order/duplicate ratio, stale online drivers, GPS accuracy distribution.
- Geo: candidates/cell/query, exact-filter rejection, hot cell/skew, ETA call fanout.
- Track completeness: expected vs received seq ranges, offline upload age, impossible jumps, archive lag.
- Realtime: committed trip version → passenger delivery, reconnect/resume rate.
- Per-country SLO и dependency map; global aggregate не должен скрывать отказ одной страны.
- Synthetic ride в каждой country plane проверяет create, assign, updates, completion и replay без реального платежа.

## Эволюция решения и миграции

1. Один country/metro: relational trip/driver state, PostGIS nearby, append-only location table.
2. Рост telemetry: вынести event log, latest KV и archive; PostGIS оставить exact/analytics.
3. Hot metros: H3 bucket sharding, independent dispatch partitions, load shedding.
4. Новая страна: отдельные stores/keys/quotas/deploy, global routing с last-known-good config; не растягивать прежний DB.
5. Новый track algorithm: version derived output, shadow compute, compare, переключить reader; raw events не переписывать.

## Trade-offs и альтернативы

- PostGIS проще и точнее на умеренной нагрузке. H3/KV легче масштабирует moving candidates, но требует exact filter, TTL и reconciliation.
- Broadcast всем nearby drivers минимизирует time-to-first-accept, но создаёт notification storm. Малые waves уменьшают noise ценой dispatch latency.
- Strong transaction trip+driver проще доказывает единственного победителя. Раздельные services/stores требуют reservation protocol и failure recovery, которые здесь не окупаются исходной нагрузкой.
- Хранить каждый point в hot SQL удобно для query, но дорого для WAL/index. Event log + columnar/object archive улучшает throughput, усложняя ad-hoc access.
- Country-local authority изолирует failures и PII. Global active-active trip снижает latency roaming, но добавляет cross-region conflict/legality и не требуется условием.

## Типичные ошибки

- Считать nearest по H3 hops окончательным расстоянием и не проверять geometry/ETA.
- Назначать driver тому, чей push accept пришёл первым в application process, без atomic state transition.
- Использовать lock без fencing: старый holder после pause продолжает менять trip.
- Перетирать latest location по arrival time: offline batch откатывает водителя назад.
- Хранить только «усреднённый» track и терять raw evidence/algorithm version.
- Игнорировать available drivers location load: in-trip 20,8k peak не является полной ingestion capacity.
- Делать общий global dependency для booking: падение identity/config в X каскадирует в Y.

## Когда применять

Дизайн подходит regional ride-hailing с frequent telemetry, geo candidate search и строгим assignment invariant. На интервью сначала считают location events, затем отделяют transient position от trip transaction и history. Самые важные доказательства: почему accept даёт ровно одного business winner, как stale cell не создаёт ложного driver и почему offline points не ломают порядок.

## Источники

- Исходное условие Avito: `90 Вложения/Авито/Авитою. Систем дизайн.txt`, проверено 2026-07-18.
- [H3 indexing](https://github.com/uber/h3/blob/v4.5.0/website/docs/highlights/indexing.md) — H3 project, tag `v4.5.0`, проверено 2026-07-18.
- [H3 grid traversal](https://github.com/uber/h3/blob/v4.5.0/website/docs/api/traversal.mdx) — H3 project, tag `v4.5.0`, проверено 2026-07-18.
- [PostGIS 3.6.4 release notes](https://postgis.net/docs/release_notes.html) — PostGIS project, версия 3.6.4 от 2026-06-08, проверено 2026-07-18.
- [RFC 6455: The WebSocket Protocol](https://datatracker.ietf.org/doc/html/rfc6455) — IETF, RFC 6455, декабрь 2011, проверено 2026-07-18.
- [Regulation (EU) 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj) — European Union, GDPR, проверено 2026-07-18; один из региональных правовых regimes, не универсальная глобальная policy.
