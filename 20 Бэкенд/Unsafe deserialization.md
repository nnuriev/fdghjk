---
aliases:
  - Insecure deserialization
  - Deserialization of untrusted data
  - Небезопасная десериализация
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/валидация
статус: проверено
---

# Unsafe deserialization

## TL;DR

Unsafe deserialization возникает, когда недоверенные bytes не ограничиваются восстановлением простых данных, а управляют типами, object graph, lifecycle hooks или полями domain object. В таком runtime «прочитать сообщение» способно означать создать произвольный класс, вызвать доступный gadget, обойти constructor invariant, подменить privileged field или исчерпать память на графе объектов.

Надёжная граница принимает bounded data format с фиксированной schema, декодирует его в inert DTO из примитивов, отвергает неизвестные/полиморфные типы, проверяет структуру и business constraints, затем явно создаёт domain object из DTO и server-side identity. Native object serialization (`pickle`, Java Serialization и аналоги) не принимают от недоверенного источника.

Подпись/HMAC доказывает происхождение bytes только в заданной trust model. Она не делает опасный object graph безопасным, не ограничивает resource cost и не спасает от скомпрометированного или чрезмерно полномочного producer.

## Область применимости

Заметка рассматривает CWE-502 в CWE 4.20 от 2026-04-30, Python `pickle` 3.14.6, Java Object Serialization/ObjectInputFilter в Java SE 25 и generic API/queue/cache boundaries.

«Serialization» здесь означает внешнее представление данных или object graph. Не вся десериализация уязвима: bounded JSON в DTO не исполняет произвольный Python-код сам по себе. Но JSON становится опаснее, если framework разрешает attacker-controlled `@type`, generic object resolver, callbacks или прямое mass assignment в domain entity.

Вне scope остаются эксплуатационные gadget chains и уязвимости конкретных сторонних libraries. Их набор меняется; архитектурное правило не зависит от списка известных gadgets.

## Ментальная модель

Есть два разных контракта.

**Data decoding:**

```text
bytes
  -> fixed grammar
  -> fixed DTO types
  -> validation
  -> explicit domain construction
```

**Object graph restoration:**

```text
bytes choose types/references/state
  -> runtime loads classes
  -> allocates graph
  -> invokes hooks/resolvers
  -> object becomes live inside process
```

Во втором случае payload участвует в управлении программой ещё до того, как application code получил «готовый объект» и начал validation. Проверять поля после dangerous `readObject()` или `pickle.loads()` поздно: side effect мог произойти во время чтения.

Object deserializer — миниатюрный virtual machine. Чем больше он умеет восстанавливать автоматически, тем больше capabilities получает вход.

## Как устроено

### Откуда берётся эффект

Object serialization сохраняет не только scalar values. Формат может кодировать class name, reference graph, constructor/reduction rule, custom hook, proxy/type metadata или external object lookup. Runtime и classpath поставляют executable building blocks. Attacker не обязан загружать новый код, если существующие types можно соединить в нежелательную цепочку.

Даже без code execution остаются другие последствия:

- constructor/setter validation обходится прямым восстановлением private fields;
- client присваивает себе `role`, `owner`, `approved` или внутреннее состояние workflow;
- recursive/shared graph, огромный array или collection исчерпывают memory/CPU;
- object lookup читает файл, URL, database row или secret;
- несовместимая версия создаёт частично инициализированный object и fail-open path.

CWE-502 поэтому включает integrity, access control и availability, а не только RCE.

### Trust boundary важнее location

Недоверенными считаются bytes из HTTP, message broker, cache, database column, object storage, backup и inter-service RPC, если writer не входит в тот же security boundary. «Это наша Kafka» не доказывает trust: topic ACL, producer identity, replay, compromised service и migration script тоже влияют на содержимое.

Перед decode фиксируют producer, schema version, максимальный size и допустимый parser. [[20 Бэкенд/Аутентификация и авторизация на уровне API|Аутентификация producer]] отвечает, кто отправил message. Schema/semantic validation отвечает, что этому producer разрешено выразить.

### Безопасный DTO pipeline

Предпочтительный pipeline:

1. Ограничить raw bytes до allocation и decompression.
2. Если protocol использует authenticated envelope, проверить fixed-size header, key ID, MAC/signature и freshness над точными raw bytes до object deserializer.
3. Выбрать decoder по server-known media type и explicit schema version.
4. Декодировать в DTO с закрытыми primitive fields и bounded collections. Generic `map[string]any` не переносится прямо в domain layer.
5. Отклонить unknown fields либо сохранить их как inert extension data по явной versioning policy. Fields вроде `@type`, class name и function name не управляют resolver.
6. Проверить type/range/length/cardinality/cross-field rules через [[20 Бэкенд/Валидация и модель ошибок API|валидацию API]].
7. Явно построить domain command. Principal, tenant, role, price, approval и state читаются из server-side источников, а не доверяются DTO.
8. Выполнить authorization и business invariant непосредственно перед effect.

`json.Unmarshal` или аналогичный parser решает только шаг 4. Остальные шаги не появляются автоматически.

### Native object formats

Документация Python 3.14.6 прямо предупреждает: `pickle` небезопасен, malicious data способен выполнить произвольный код во время unpickling; принимать можно только trusted data. Ограничение subclass `Unpickler.find_class` уменьшает поверхность, но Python docs предупреждают обходить опасные источники целиком. Для внешнего protocol выбирают data format вроде JSON и собственную schema.

Java Serialization восстанавливает class instances и вызывает serialization callbacks. `ObjectInputFilter` в Java SE 25 проверяет classes, array sizes, graph depth, reference count и bytes. Oracle подчёркивает, что untrusted deserialization inherently dangerous и её следует избегать. Filter не активируется «по смыслу приложения»: его нужно сконфигурировать для конкретного context.

JEP 290 добавил filtering в JDK 9. Он сознательно не определяет готовую allowlist policy и не исправляет опасные classes. Это safety net для legacy boundary, а не эквивалент DTO decoder.

### Почему allowlist типов недостаточна

Allowlist полезнее denylist, потому что новые gadgets постоянно обнаруживаются. Но разрешённый type сам способен:

- иметь опасный callback;
- содержать field типа `Object` и вложить неожиданный type;
- выделить огромный array или глубокий graph;
- изменить поведение после library upgrade;
- нарушить domain invariant при неожиданной комбинации полей.

Поэтому filter одновременно ограничивает types **и** graph metrics, а результат всё равно преобразуется в DTO/domain command. Чем меньше classpath у isolated worker, тем меньше gadgets, но это defense in depth.

### Подпись и шифрование

HMAC перед deserialization закрывает tampering, если ключ есть только у доверенных producers и verifier проверяет raw bytes раньше dangerous parser. Он не помогает, если любой tenant или client владеет общим signing key, producer скомпрометирован или legitimate producer может создать опасный graph.

Encryption скрывает содержимое, но не подтверждает безопасную semantics. AEAD даёт integrity ciphertext, однако после успешной проверки plaintext всё равно проходит schema, resource и authorization checks.

Нельзя сначала `deserialize`, а затем проверять embedded signature: опасный код/allocations происходят до authentication.

### Resource bounds

Safe data format тоже способен вызвать DoS. Ограничивают:

- raw и decompressed bytes;
- nesting depth;
- число objects/references;
- array/string/map lengths;
- numeric precision/range;
- parse time и concurrent decoders;
- total retained memory после decode.

Предел одного message не заменяет bounded concurrency: тысяча сообщений по допустимому максимуму всё равно исчерпает [[10 Основы CS/Исчерпание ресурсов процесса|ресурсы процесса]]. Полная схема лимитов до и после decompression, parser и aggregate admission разобрана в [[20 Бэкенд/Ограничения размера входных данных и исчерпание ресурсов|заметке о ресурсных ограничениях]].

### Версии schema

Object serialization тесно связывает wire format с runtime class layout. Изменение classpath или поля меняет compatibility и иногда security behavior. Явная schema version позволяет:

- выбрать отдельный decoder/validator;
- мигрировать DTO до текущей domain model;
- ограничить срок поддержки старого protocol;
- не включать generic polymorphism ради совместимости.

Unknown field rejection лучше ловит случайную/злонамеренную семантику, но мешает forward compatibility. Компромисс — versioned extension map из inert values, которую старый service не переносит в privileged fields и не интерпретирует как type/function.

## Сквозной пример: команда перевода между счетами

Endpoint принимает JSON schema v1:

```text
TransferDTO v1 {
  to_account: string[1..64]
  amount_minor: integer[1..1_000_000]
  memo?: string[0..200]
}
```

Приходит bounded body:

```json
{
  "to_account": "A-17",
  "amount_minor": 500,
  "role": "admin",
  "@type": "TransferCommand"
}
```

1. Body reader подтверждает размер до 8 KiB. Content type и schema version известны.
2. Strict DTO decoder видит `role` и `@type` как unknown fields и возвращает `400 invalid_fields`. Type resolver не вызывается, domain object не создаётся.
3. Второй request содержит только разрешённые поля. Decoder создаёт inert `TransferDTO`.
4. Validator проверяет range и существование `to_account` в допустимом tenant scope.
5. `payer_account` и principal берутся из authenticated server context. Application явно вызывает `NewTransferCommand(payer, dto.to_account, dto.amount_minor, dto.memo)`; client не задаёт role, owner или approval state.
6. Domain service повторно проверяет authorization и баланс перед commit.

Наблюдаемый результат: attacker-controlled type metadata и privileged field не доходят до runtime/domain model. Валидный message выражает только три заранее разрешённые data values.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До JDK 9 → JDK 9 | У Java Serialization не было стандартного общего `ObjectInputFilter` API | JEP 290 добавил class и graph-metric filtering | Legacy streams можно ограничить без custom subclass, но policy нужно задать, а untrusted object serialization всё ещё рекомендуется избегать | JEP 290 |
| Python 3.14 | `pickle` protocol 4 был default в Python 3.8–3.13 | Protocol 5 стал default | Wire compatibility изменилась, но security invariant не изменился: unpickle только trusted data | Python 3.14.6 `pickle` docs |

## Trade-offs и альтернативы

### Data format или native object serialization

JSON/CBOR/Protobuf с фиксированной schema требуют explicit mapping и migration code, зато не дают payload автоматически выбирать runtime class. Native format быстрее подключить внутри монолита и сохраняет сложный graph, но связывает protocol с classpath и расширяет effect during decode. На недоверенной границе выигрывает data format + DTO.

### Strict unknown rejection или forward compatibility

Reject unknown fields рано обнаруживает drift и mass assignment. Ignore unknown упрощает rolling upgrade, но скрывает опечатки и будущую security semantics. Versioned schema плюс inert extensions даёт совместимость без generic type activation.

### Filter или изоляция

ObjectInputFilter/type allowlist уменьшает legacy risk с малой переделкой. Isolated process/container ограничивает filesystem/network/CPU blast radius. Оба слабее отказа от dangerous format, но полезны вместе во время миграции.

### Signed payload или online lookup

Signed self-contained state экономит lookup и переносится между services, но producer key становится правом создавать весь допустимый state, а revocation/schema bugs живут до expiry. Opaque ID с server-side lookup даёт свежий authoritative state и проще ограничивает поля, оплачивая latency/storage dependency.

## Типичные ошибки

### Validation запускают после native deserializer

- **Неверное предположение:** опасны только значения готового object.
- **Симптом:** side effect или resource spike возникает до ошибки validation.
- **Причина:** type resolution, allocation и hooks выполняются во время deserialization.
- **Исправление:** не принимать native object format; проверять bounded authenticated envelope, затем inert DTO.

### Считают JSON автоматически безопасным

- **Неверное предположение:** текстовый формат не создаёт objects с поведением.
- **Симптом:** `@type`/polymorphic metadata выбирает неожиданный class либо fields напрямую меняют domain entity.
- **Причина:** framework поверх JSON включил type resolver или mass assignment.
- **Исправление:** fixed DTO types, отключённый generic polymorphism, explicit mapping и unknown-field policy.

### Подпись проверяют внутри object

- **Неверное предположение:** embedded signature защитит deserializer.
- **Симптом:** untrusted graph обрабатывается до cryptographic failure.
- **Причина:** для чтения signature уже вызван dangerous parser.
- **Исправление:** MAC/signature во внешнем bounded envelope над raw payload, проверка до object deserialization.

### Allowlist не ограничивает graph

- **Неверное предположение:** разрешённые classes всегда дешёвы.
- **Симптом:** memory/CPU исчерпываются arrays, depth или references.
- **Причина:** type policy не задаёт resource policy.
- **Исправление:** limits на bytes, arrays, depth, refs, time и concurrency.

### Domain object восстанавливают напрямую

- **Неверное предположение:** private fields/constructor защищают invariant после deserialize.
- **Симптом:** `owner`, `role`, state machine или cached decision принимает client-supplied значение.
- **Причина:** restoration обошёл controlled constructor и authoritative lookup.
- **Исправление:** DTO из данных; domain object создаётся factory из server context и валидированных values.

### Доверяют внутренней очереди

- **Неверное предположение:** private network делает producer trusted.
- **Симптом:** один скомпрометированный service влияет на consumer runtime с более широкими правами.
- **Причина:** trust boundary определён topology, а не producer identity/capability.
- **Исправление:** per-producer auth, schema authorization, отдельные topics/keys и тот же safe decoder.

## Когда применять

Inventory ищет не только методы с названием `deserialize`: `pickle.load`, `ObjectInputStream`, YAML object tags, generic JSON polymorphism, cache/session blobs, RPC `Any`, message conversion и ORM-stored object fields. Для каждого source фиксируют producer trust, format, type policy, resource budget и domain mapping.

Практическое правило: недоверенные bytes могут выбирать значения, но не runtime types, functions, ownership и privileged state. Если decoder создаёт «готовый domain object», граница слишком широкая до тех пор, пока обратное не доказано по API и configuration.

## Источники

- [CWE-502: Deserialization of Untrusted Data](https://cwe.mitre.org/data/definitions/502.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [Deserialization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [pickle — Python object serialization](https://docs.python.org/3.14/library/pickle.html) — Python Software Foundation, Python 3.14.6, проверено 2026-07-18.
- [ObjectInputFilter](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/io/ObjectInputFilter.html) — Oracle, Java SE 25 / JDK 25, проверено 2026-07-18.
- [JEP 290: Filter Incoming Serialization Data](https://openjdk.org/jeps/290) — OpenJDK, delivered в JDK 9, обновлено 2022-08-15, проверено 2026-07-18.
- [OWASP Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/) — OWASP, ASVS 5.0.0 от 2025-05-30, проверено 2026-07-18.
