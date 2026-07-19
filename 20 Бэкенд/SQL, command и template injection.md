---
aliases:
  - Injection
  - SQL injection
  - OS command injection
  - Server-side template injection
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/валидация
статус: проверено
---

# SQL, command и template injection

## TL;DR

Injection возникает, когда данные пересекают границу интерпретатора и становятся частью управляющего языка. Для SQL это текст запроса, для shell — командная строка, для template engine — исходный текст шаблона или выражение. Проверка «строка выглядит безопасно» не восстанавливает потерянную границу.

Основное правило: управляющую структуру создаёт разработчик, недоверенное значение передаётся через типизированный data channel. SQL использует bind parameters, процесс запускается через фиксированный executable и массив аргументов без shell, шаблон заранее выбирается и компилируется из доверенного набора, а пользовательские значения попадают только в data model. Если конкретный фрагмент нельзя параметризовать, например SQL identifier или направление сортировки, его выбирают из закрытого отображения `enum -> константа`, а не очищают произвольную строку.

## Область применимости

Заметка покрывает CWE-89, CWE-78 и CWE-1336 в редакции CWE 4.20 от 2026-04-30, а также требования OWASP ASVS 5.0.0. Речь идёт о backend-коде, который передаёт недоверенные значения SQL engine, операционной системе или server-side template engine.

Вне scope остаются XSS в уже сформированном HTML, LDAP/XPath/NoSQL-specific синтаксис и эксплуатационные payloads. Механизм у них родственный, но конкретный data/code boundary и способ параметризации различаются.

## Ментальная модель

Интерпретатор видит не намерение разработчика, а последовательность токенов. Если приложение собирает эту последовательность конкатенацией, один и тот же байт может означать часть значения или управляющий символ:

```text
untrusted bytes
    + trusted prefix/suffix
    -> parser tokenizes the combined string
    -> data may become syntax
    -> interpreter executes a different program
```

Безопасная конструкция передаёт две сущности раздельно:

```text
trusted program / AST / template
untrusted typed values
    -> binding API preserves the boundary
    -> interpreter cannot retokenize a value as program syntax
```

Экранирование пытается закодировать границу внутри одной строки. Оно зависит от точного диалекта, позиции, encoding, режима parser и числа декодирований. Структурный API делает границу частью интерфейса. Это сильнее.

## Как устроено

### Общий причинный механизм

У каждой injection-уязвимости есть четыре звена:

1. Источник допускает внешнее влияние. Им бывает не только HTTP body: header, cookie, запись из БД, сообщение очереди, имя файла, конфигурация tenant или ответ другого сервиса тоже остаются недоверенными.
2. Код объединяет значение с управляющим текстом либо разрешает значению выбирать исполняемый тип/функцию.
3. Downstream parser разбирает уже объединённое представление.
4. Эффект выполняется с правами backend-процесса, database role или template runtime.

Stored или second-order injection разрывает эти шаги во времени: строку безопасно сохраняют как данные, но позже подставляют в запрос, команду или шаблон. Проверять только первоначальный HTTP entry point недостаточно; защита ставится у каждого sink.

Инварианты безопасного sink:

- программа и данные передаются разными параметрами API;
- набор допустимых dialect, executable, template, helper и dynamic identifier закрыт сервером;
- декодирование выполняется один раз в определённом слое, после чего downstream получает каноническое значение;
- сервисный account ограничивает последствия ошибки; [[20 Бэкенд/Аутентификация и авторизация на уровне API|авторизация]] данных не заменяет безопасный вызов интерпретатора;
- ошибки не возвращают клиенту полный query, command line, stack trace или template context;
- security-тесты проходят все пути к sink, включая фоновые задачи и импорт сохранённых данных.

### SQL injection

Prepared statement или parameterized query передаёт SQL text и значения отдельно. Placeholder связывает именно value. Он обычно не заменяет имя таблицы, столбца, keyword или `ASC`/`DESC`. Такие элементы проектируют как закрытый выбор:

```text
sort=created_desc -> "created_at DESC"
sort=amount_asc   -> "amount ASC"
всё остальное    -> 400
```

После выбора константы запрос всё равно обязан ограничивать tenant и object scope. Параметризация предотвращает смену грамматики, но не исправляет забытый `WHERE tenant_id = ?`, чрезмерные права database role или логическую ошибку авторизации. ORM тоже не даёт автоматической гарантии: raw query, динамический fragment и string interpolation снова открывают boundary.

Stored procedure безопасна лишь пока внутри не строит динамический SQL конкатенацией. Ручное escaping менее надёжно bind parameters и допустимо только там, где конкретный driver/DBMS не предоставляет структурного механизма; dialect и режим соединения становятся частью доказательства корректности.

### OS command injection

Самая сильная защита — не вызывать системную утилиту, если ту же операцию даёт library API. Если процесс всё же нужен:

- executable задаётся константой или выбирается по server-side enum;
- shell не участвует;
- каждый argument передаётся отдельным элементом `argv`;
- рабочий каталог, environment и разрешённые файлы задаёт приложение;
- аргументы проверяются по бизнес-типу, длине и allowlist.

Отсутствие shell убирает интерпретацию shell metacharacters, но остаётся **argument injection**: вызываемая программа сама может трактовать строку, начинающуюся с option prefix, как флаг. Поэтому «мы используем `execve`, а не shell» — необходимое, но не достаточное доказательство. Для каждого executable фиксируют допустимые flags, используют `--` как разделитель только если конкретная программа его документирует, и не разрешают пользователю выбирать executable или произвольный option.

На уровне ОС процесс запускают от [[20 Бэкенд/Least privilege|service account с минимальными правами]], ограничивают ему filesystem/network access и задают resource bounds. Это уменьшает blast radius, но не превращает небезопасную командную строку в безопасную.

### Template injection

Нужно разделять две операции:

```text
parse(trusted template source) -> compiled template
render(compiled template, untrusted data model) -> output
```

Если пользовательское значение попадает в `parse`, engine рассматривает его как template syntax. Доступный эффект зависит от engine: вызов exposed helper, чтение свойств, создание дорогого выражения или выполнение функции. Auto-escaping решает другую задачу: кодирует **результат** в HTML/JS/URL-контексте. Оно не делает недоверенный template source безопасным.

Надёжный дизайн хранит шаблоны как versioned application artifacts и принимает от клиента только `template_id`, отображаемый на заранее скомпилированный объект. Data model состоит из DTO с минимальным набором полей. Function registry закрыт; в нём нет файловой системы, сети, process execution, secrets или generic reflection.

Если продукт действительно исполняет пользовательские шаблоны, это уже запуск недоверенного кода. Нужны отдельный процесс/tenant, capability-based API, CPU/memory/output/time limits и отсутствие секретов. Sandbox template engine остаётся defense in depth: новая функция или dependency способна расширить набор доступных gadgets.

### Валидация и escaping

[[20 Бэкенд/Валидация и модель ошибок API|Валидация входа]] подтверждает бизнес-тип: `amount` положителен, `sort` входит в enum, identifier имеет ожидаемую длину. Она сокращает поверхность атаки и даёт понятную ошибку, но не заменяет binding. Свободный текст вроде фамилии с апострофом может быть полностью легитимным; удаление punctuation портит данные и всё равно не доказывает безопасность во всех parser contexts.

Escaping применяется к точному **output context** после того, как архитектура максимально разделила code и data. HTML text, HTML attribute, JavaScript string, SQL literal и shell argument имеют разные правила. Универсальной функции `sanitize()` для всех sink не существует.

## Сквозной пример: формирование отчёта

Endpoint принимает:

```json
{
  "status": "O'Reilly",
  "sort": "created_desc",
  "format": "pdf",
  "template_id": "invoice_v3",
  "customer_name": "{{customer}}"
}
```

Символы здесь выбраны как обычные данные, а не как эксплуатационный payload.

1. `sort` отображается на константу `created_at DESC`. Неизвестное значение получает `400`.
2. SQL text фиксирован:

   ```sql
   SELECT tenant_id, status
   FROM reports
   WHERE tenant_id = @tenant AND status = @status
   ORDER BY created_at DESC;
   ```

   `@tenant=t1` и `@status=O'Reilly` передаются как parameters. В SQLite 3.51.0 тестовая таблица с тремя строками вернула ровно `t1|O'Reilly`; апостроф остался частью значения и не изменил query structure.
3. `format=pdf` отображается на фиксированный executable `report-renderer` и фиксированный flag. Путь входного файла создаёт сервер. Строка `format` не попадает в shell или command name.
4. `template_id=invoice_v3` выбирает заранее скомпилированный шаблон. `customer_name` передаётся как field data model. Последовательность `{{customer}}` выводится как текст и не проходит повторный `parse`.
5. Database role читает только представление отчётов текущего сервиса; renderer работает без сетевого доступа и секретов.

Наблюдаемый результат: один и тот же внешний ввод остаётся данными на трёх разных границах. SQL возвращает только строку tenant `t1`, command contract не меняется, template engine не получает новый template expression.

## Trade-offs и альтернативы

### Bind parameters или ручное escaping

Binding переносит правила quoting в protocol/driver и сохраняет грамматику SQL. Ручное escaping дешевле внедрить в единичный legacy fragment, но требует доказать dialect, encoding и parser mode на каждом пути. Для values выбирают binding. Для identifiers — закрытое отображение на literals.

### Library API или внешний процесс

Library API не имеет shell boundary и проще типизируется, зато увеличивает dependency footprint внутри процесса. Внешняя утилита изолирует crash и может быть единственной реализацией формата, но добавляет `argv`, environment, filesystem и lifecycle boundaries. Если нужен процесс, его интерфейс проектируют как малый protocol, а не как свободную command line.

### Фиксированные шаблоны или пользовательский DSL

Фиксированные шаблоны проще проверять, кэшировать и версионировать. Пользовательский DSL даёт кастомизацию, но требует признать template source кодом, изолировать исполнение и ограничить capabilities. «Sandbox flag» без ресурсных и системных границ не уравнивает эти варианты.

### WAF или исправление sink

WAF способен временно отфильтровать известный pattern и дать telemetry. Он видит сериализованный HTTP, а не окончательный parser context, пропускает internal/async paths и даёт false positives. Это аварийный слой, не замена структурному API.

## Типичные ошибки

### Один sanitizer перед всеми sink

- **Неверное предположение:** опасные символы одинаковы для SQL, shell и template engine.
- **Симптом:** после исправления одного endpoint уязвимость остаётся в другом dialect или появляется порча легитимных данных.
- **Причина:** neutralization зависит от parser context.
- **Исправление:** разделить sink-specific adapters; code/data boundary обеспечивает API, валидация подтверждает бизнес-тип.

### Placeholder используют для dynamic identifier

- **Неверное предположение:** bind parameter способен заменить любое место SQL.
- **Симптом:** driver возвращает syntax error, и разработчик откатывается к конкатенации `ORDER BY`.
- **Причина:** placeholder представляет value, а не grammar token.
- **Исправление:** отображать внешний enum на заранее заданный SQL fragment.

### Процесс запускают без shell, но аргументы произвольны

- **Неверное предположение:** массив `argv` закрывает все command injection risks.
- **Симптом:** вызываемая программа меняет режим, читает другой файл или пишет не туда.
- **Причина:** option parser самой программы интерпретирует недоверенный аргумент как control data.
- **Исправление:** фиксировать executable/flags, валидировать operand и изолировать процесс.

### Auto-escaping считают защитой template source

- **Неверное предположение:** HTML auto-escape обезвреживает template expressions.
- **Симптом:** пользовательский шаблон вызывает доступный helper до формирования HTML.
- **Причина:** escaping работает на output stage, а выражение исполняется на parse/render stage.
- **Исправление:** парсить только доверенный template source; кастомный DSL исполнять в изоляции с узкими capabilities.

### Права downstream не ограничены

- **Неверное предположение:** параметризация исключает необходимость least privilege.
- **Симптом:** единичный пропущенный sink даёт доступ ко всей БД или host.
- **Причина:** interpreter выполняет эффект с широкими service credentials.
- **Исправление:** отдельные database roles, process identity, filesystem/network policy и аудит чувствительных операций.

## Когда применять

Проверку code/data boundary проводят на каждом вызове SQL/NoSQL query builder, process execution API и template parser/render API. Особое внимание получают raw escape hatches в ORM, admin-configurable expressions, import/export pipeline, consumers очередей и миграционный код: внешнее влияние там менее заметно, но trust не появляется от хранения в собственной БД.

Практическое правило для code review: укажите неизменяемый program text, отдельный typed value channel и полномочия interpreter. Если любой из трёх пунктов нельзя показать по коду и конфигурации, граница не доказана.

## Источники

- [CWE-89: Improper Neutralization of Special Elements used in an SQL Command](https://cwe.mitre.org/data/definitions/89.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [CWE-78: Improper Neutralization of Special Elements used in an OS Command](https://cwe.mitre.org/data/definitions/78.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [CWE-1336: Improper Neutralization of Special Elements Used in a Template Engine](https://cwe.mitre.org/data/definitions/1336.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [OS Command Injection Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/OS_Command_Injection_Defense_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Injection_Prevention_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [OWASP Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/) — OWASP, ASVS 5.0.0 от 2025-05-30, проверено 2026-07-18.
