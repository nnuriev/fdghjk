---
aliases:
  - Cache and CDN
  - CDN и edge cache
  - Иерархия кэшей
tags:
  - область/проектирование-систем
  - тема/кэширование
  - архитектура/cdn
статус: проверено
---

# Cache и CDN

## TL;DR

Cache хранит повторно используемую копию результата ближе к читателю. CDN делает это на распределённых edge-узлах, а regional tier или origin shield собирает misses перед origin. Выигрыш появляется только тогда, когда повторный расчёт, network path или origin load дороже lookup в кэше.

Корректность задают четыре контракта: **cache key**, право хранить response, срок freshness и допустимое поведение после устаревания. Ошибка TTL обычно показывает старые данные; ошибка key способна показать данные другого пользователя. Поэтому сначала фиксируют все request dimensions, меняющие representation, и только потом считают hit ratio.

Глобальная invalidation не атомарна с записью в origin. Если бизнес требует немедленно запретить старое значение, TTL и purge недостаточны без versioned key, revalidation или проверки authority на read path. Stale serving и request coalescing повышают availability, но применимы лишь там, где явно допустима старая копия.

## Область применимости

HTTP cache semantics, validators и shared-cache restrictions соответствуют RFC 9111 и RFC 9110 от июня 2022 года; stale extensions — RFC 5861. Edge/tiered cache, custom cache keys и origin shield сверены с документацией Cloudflare и Amazon CloudFront на 2026-07-18. Внутренний cache произвольных объектов и его shard topology разобраны в [[30 Данные/Distributed cache и KV store|distributed cache и KV store]].

## Ментальная модель

Cache entry — materialized copy функции:

```text
representation = F(request dimensions, origin state/version)
entry = (cache_key, response metadata, body, stored_at, validators)
```

Cache key должен различать все inputs, от которых зависит `F`. Freshness разрешает некоторое время переиспользовать entry без обращения к origin. Validator (`ETag`, `Last-Modified`) позволяет спросить, осталась ли копия той же версией. Invalidation сообщает, что часть entries больше нельзя считать пригодной, но это сообщение распространяется с задержкой.

Иерархия CDN выглядит так:

```text
client -> edge cache -> regional tier / origin shield -> origin
             hit             hit                     compute/read
```

Edge уменьшает latency пользователя. Shield уменьшает fan-out к origin: misses из многих edges сходятся в меньшее число upstream fetches. Каждый новый слой добавляет собственный TTL, eviction, metrics и failure mode.

## Как устроено

### Edge, regional tier, shield и origin

Ближайший edge принимает request и ищет entry по локальному key. При miss он обращается к upper tier. Regional tier агрегирует edges одной области; origin shield находится перед origin и становится общей точкой для cache lookup и request collapsing. Только shield обращается к origin при общем miss.

Такая иерархия повышает aggregate hit ratio и сокращает число origin connections. Цена — дополнительный hop на miss, стоимость второго слоя и более сложная диагностика: `edge MISS` ещё не означает origin request, потому что shield мог ответить `HIT`.

Shield не заменяет origin capacity planning. Некэшируемый dynamic traffic проходит через все layers, а потеря горячего cache после configuration change создаёт cold-start wave. Origin обязан выдерживать согласованный miss rate либо система должна ограничивать fill concurrency и деградировать контролируемо.

### Cache key и eligibility

Для HTTP базовый primary cache key включает method и target URI; `Vary` расширяет selection заголовками, которые origin объявил значимыми. Реальная CDN policy может включать или исключать query parameters, cookies, `Accept-Encoding`, язык, device class и другие dimensions.

Слишком узкий key смешивает разные representations. Если `/profile` зависит от authenticated principal, а key содержит только URL, shared cache отдаст чужой ответ. Слишком широкий key безопаснее по изоляции, но дробит entries: случайный query parameter или полный `User-Agent` превращает каждый request в miss.

Eligibility определяют method, response status, explicit directives, authorization и policy CDN. `private` запрещает unqualified shared storage, `no-store` запрещает намеренно сохранять request/response, `no-cache` разрешает хранение, но требует validation перед reuse. Эти директивы различаются; подмена всех словом «не кэшировать» ломает reasoning.

Персональные ответы безопаснее начинать с `private` или `no-store`. Shared caching допускается только после явного определения tenant/principal dimension, защиты от cache poisoning и теста через реальный proxy. Секретный token нельзя бездумно включать в cache key: он попадёт в memory, telemetry или configuration surface. Чаще public representation отделяют от user-specific authorization result.

### TTL, Age и validators

Freshness lifetime приходит из `s-maxage`, `max-age`, `Expires` или согласованной heuristic policy. Shared cache учитывает resident time через `Age`. Fresh response обычно можно reuse без origin, только если request/response directives и локальная policy не требуют validation: например, `no-cache` заставляет проверить сохранённый ответ даже до expiry. Freshness — это разрешение на reuse, а не доказательство, что origin не изменился.

После expiry cache может выполнить conditional request. `If-None-Match` с `ETag` или `If-Modified-Since` с `Last-Modified` позволяет origin вернуть `304 Not Modified` без нового body. Validator должен соответствовать representation: один `ETag` для двух разных encodings или languages без корректного `Vary` снова смешивает варианты.

Короткий TTL уменьшает worst-case staleness, но повышает revalidation traffic. Длинный TTL увеличивает hit ratio, однако требует versioned URLs или надёжной purge strategy для срочных изменений. Immutable assets удобно публиковать под content/version key и кэшировать долго: новая версия получает новый URL, старая не меняет смысл.

### Invalidation и versioning

Есть три основных механизма:

- TTL ограничивает срок reuse без control-plane сообщения;
- purge удаляет entries по URL, prefix или surrogate tag;
- versioned key делает новое состояние новым cache object для rollout, но сам не отзывает старый известный URL.

Purge глобальной CDN распространяется не мгновенно и не входит в transaction origin database. Write уже committed, а часть edges ещё способна вернуть старую копию. Поэтому contract определяет допустимое окно и поведение клиента. Versioned key решает переключение сотрудничающего клиента на новую representation, но caller со старым URL всё ещё способен запросить прежний object. Для юридического запрета, permission revoke или остатка с жёстким инвариантом старый key надо отклонить до cache reuse: через online authorization/version-bound grant, короткоживущий signed URL с ограниченным TTL либо другой проверяемый deny path. Purge может ускорить удаление copies, но не подменяет эту границу, если у него нет доказанного upper bound.

Invalidate-after-commit избегает удаления кэша перед неуспешной записью, но оставляет окно stale read. Update cache после write создаёт другой race: более медленный старый writer может записать прежнее значение позже нового. Без version compare cache остаётся derived state, который безопаснее удалить и восстановить из owner.

### Stale serving и ошибки origin

RFC 5861 определяет `stale-while-revalidate`: cache может временно отдать stale response и обновить его асинхронно. `stale-if-error` разрешает старую копию при ошибке origin. Эти режимы превращают часть origin outage в bounded staleness и снижают user latency.

Старая копия допустима не всегда. Product catalog или avatar часто переживут минуты stale. Revoked permission, account balance, one-time secret и результат destructive command — нет. Stale policy задают по классу данных и status, а не включают глобальным переключателем.

Negative caching уменьшает повтор дорогих `404`, но TTL должен учитывать создание ресурса. Кэшировать `500` надолго опасно: transient failure превращается в устойчивый outage даже после восстановления origin.

### Stampede и request coalescing

Когда популярный entry истекает одновременно на многих nodes, все misses идут к origin. Это cache stampede: кэш формально работает, а backend получает скачок именно в момент expiry или cold start.

Request coalescing, или single-flight, разрешает один fill на `(cache key, layer)`, а остальные requests ждут его результат или получают stale copy. Jitter разносит expiry; soft TTL запускает background refresh до hard deadline; origin shield объединяет misses разных edges.

Fill lock тоже ограничивают deadline. Если единственный filler завис, тысячи waiters не должны ждать бесконечно. После timeout policy выбирает stale response, независимый bounded attempt или controlled failure. Один global lock на prefix создаст ненужный head-of-line blocking; coalescing работает на точном cache key.

### Наблюдаемость и безопасность

Разделяют `HIT`, `MISS`, `STALE`, `REVALIDATED`, `BYPASS` и `ERROR`, причём по каждому layer. Нужны origin request rate/bytes, fill latency, collapsed waiters, object age, eviction, purge propagation, key cardinality и доля response classes. Общий hit ratio маскирует ситуацию, где дешёвые assets дают 99% hits, а дорогой endpoint всегда проходит в origin.

Cache key и response metadata проверяют как security boundary. Query normalization, host rewriting и unkeyed headers способны создать cache poisoning или deception. Access logs не должны записывать authorization, session cookies и private key dimensions. CDN-origin channel аутентифицируют, а прямой обход CDN ограничивают, если origin доверяет добавленным edge headers.

## Пример или трассировка

`GET /catalog/42` возвращает public representation с `Cache-Control: public, s-maxage=60, stale-while-revalidate=30` и `ETag: "v17"`.

1. Первый request приходит в edge `E1`: local miss. Shield `S` тоже не имеет entry, поэтому начинает один origin fetch.
2. Пока fetch идёт, ещё 200 requests для того же key приходят из нескольких edges. На `S` они coalesce вокруг одного fill; origin получает один request, а не 201.
3. Origin возвращает version `v17`. Shield и edges сохраняют response; дальнейшие requests получают `HIT` с растущим `Age`.
4. Через 60 секунд первый request может получить stale `v17`, а edge асинхронно отправляет conditional request `If-None-Match: "v17"` через shield. При неизменном origin ответ `304` обновляет freshness без body.
5. Редактор публикует `v18` и отправляет purge после commit. До распространения purge отдельный edge ещё может вернуть `v17` в допустимом stale window. Для rollout manifest может сразу сослаться на versioned URL `v18`, не ожидая purge; старый URL при этом намеренно остаётся ссылкой на `v17` и для security revoke требует отдельного deny-механизма.

Наблюдаемый результат: shield и coalescing защищают origin от fan-out, validators экономят body, а contract честно допускает bounded stale response. Для `/me` с private data та же policy была бы небезопасна.

## Trade-offs

Edge cache минимизирует user latency, но размножает cold misses и invalidation targets. Regional/shield layer повышает aggregate hit ratio и бережёт origin, зато добавляет hop и платный request layer. Для маленькой географии один regional cache иногда дешевле полной CDN.

TTL прост и продолжает работать при control-plane outage. Purge быстрее меняет mutable content, но имеет propagation lag. Versioned immutable keys дают наиболее предсказуемую корректность и rollback, однако требуют менять references и очищать старые objects lifecycle policy.

Validator сохраняет bandwidth и подтверждает актуальность через origin. Stale serving убирает origin из critical path на короткое окно. Выбор зависит от допустимой stale-ness: availability optimization не должна ослаблять security или денежный инвариант.

Узкий key повышает hit ratio, широкий сохраняет варианты. Сокращать key можно только после доказательства, что удалённое dimension не меняет response. Одной статистики hits для этого недостаточно.

## Типичные ошибки

### Tenant или identity отсутствует в key

- **Неверное предположение:** одинаковый URL означает одинаковый response.
- **Симптом:** пользователь получает персональные данные другого tenant.
- **Причина:** authorization/cookie меняет representation, но shared cache key этого не отражает.
- **Исправление:** `private`/`no-store` по умолчанию; public representation отделить либо включить проверенное dimension и протестировать isolation.

### Purge считают частью database transaction

- **Неверное предположение:** после write все edges мгновенно удалили entry.
- **Симптом:** часть пользователей видит прежнее состояние после подтверждённой записи.
- **Причина:** invalidation — отдельное распределённое сообщение.
- **Исправление:** определить stale window, versioned keys или authoritative validation для критичного read.

### TTL истекает синхронно

- **Неверное предположение:** каждый miss независимо дешёв.
- **Симптом:** origin перегружен ровно на границе expiry или после deploy cache nodes.
- **Причина:** одинаковый hot key одновременно заполняют многие callers/layers.
- **Исправление:** request coalescing, jitter, soft refresh, shield и bounded origin concurrency.

### Ошибка origin кэшируется как обычный object

- **Неверное предположение:** любой response полезно сохранить на общий TTL.
- **Симптом:** восстановившийся origin остаётся недоступен пользователям до expiry cached `500`.
- **Причина:** status class и negative-cache policy не разделены.
- **Исправление:** разрешить короткий negative cache только для ожидаемых outcomes; transient failures не сохранять либо использовать безопасный stale success.

### Hit ratio измеряется одной цифрой

- **Неверное предположение:** высокий общий hit ratio означает защищённый origin.
- **Симптом:** дешёвая статика скрывает постоянные misses дорогой генерации.
- **Причина:** метрика не взвешена по endpoint, bytes и origin cost.
- **Исправление:** hit/miss и saved origin work по key class и каждому cache layer.

## Когда применять

Cache полезен для повторяемых reads, где bounded staleness или revalidation дешевле вычисления заново. CDN добавляют, когда пользователи географически распределены, bytes велики, edge security/termination нужен отдельно или origin необходимо защитить от широкого fan-out.

До rollout зафиксируйте eligibility, полный cache key, TTL и validators, private-data policy, purge SLA, stale behavior, coalescing и capacity origin при cold cache. Если нельзя назвать максимальную допустимую stale-ness, кэш пока не имеет correctness contract.

## Источники

- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111.html) — IETF, STD 98 / RFC 9111, июнь 2022, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97 / RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html) — IETF, RFC 5861, май 2010, проверено 2026-07-18.
- [Cache keys](https://developers.cloudflare.com/cache/how-to/cache-keys/) — Cloudflare, online-документация обновлена 2026-04-17, проверено 2026-07-18.
- [Tiered Cache](https://developers.cloudflare.com/cache/how-to/tiered-cache/) — Cloudflare, online-документация обновлена 2026-06-05, проверено 2026-07-18.
- [Use Amazon CloudFront Origin Shield](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/origin-shield.html) — Amazon Web Services, CloudFront online-документация, проверено 2026-07-18.
- [Understand the cache key](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/understanding-the-cache-key.html) — Amazon Web Services, CloudFront online-документация, проверено 2026-07-18.
