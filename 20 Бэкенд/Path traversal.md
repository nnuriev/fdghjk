---
aliases:
  - Directory traversal
  - Обход каталогов
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/файловые-системы
статус: проверено
---

# Path traversal

## TL;DR

Path traversal возникает, когда внешнее имя участвует в выборе файла, а приложение доказывает допустимость строки, но не ограничивает объект, который в итоге откроет файловая система. `..`, абсолютные пути, альтернативные разделители, повторное декодирование, symbolic links, mount points и гонка между проверкой и открытием способны вывести операцию за разрешённый каталог.

Самый узкий контракт — принимать opaque ID и отображать его в server-side путь. Если клиенту действительно нужен относительный путь, его один раз декодируют, проверяют как логическое имя, преобразуют в platform path и открывают относительно заранее открытого directory handle с ограничениями разрешения пути. `Clean`, `Join`, canonical path и проверка строкового prefix полезны только как отдельные этапы: они не заменяют атомарное ограничение filesystem resolution.

Path containment не заменяет authorization. Файл может лежать внутри общего root, но принадлежать другому tenant или требовать другого действия; это проверяется по server-side metadata до read, write, rename или delete.

## Область применимости

Заметка рассматривает CWE-22 в CWE 4.20 от 2026-04-30, файловые API Go 1.26.5 и Linux `openat2(2)` начиная с Linux 5.6. Модель относится к downloads, uploads, template/theme lookup, archive extraction, log export, image processing и любому API, где вход выбирает file или directory.

Вне scope остаются права UNIX/Windows ACL как самостоятельная тема и эксплуатационные payloads. Если путь попадает в shell command, дополнительно возникает [[20 Бэкенд/SQL, command и template injection|command injection]]; filesystem containment не экранирует shell syntax.

## Ментальная модель

Строка пути — имя, а не объект. Между ними есть несколько интерпретаторов:

```text
HTTP representation
  -> percent/form decoding
  -> application logical path
  -> OS-specific separators and volumes
  -> filesystem walk through directories, links and mounts
  -> file handle
```

Security invariant формулируется на последнем шаге:

```text
открытый объект находится под разрешённым root
AND относится к principal/tenant
AND допускает запрошенную операцию
```

Проверка `path does not contain "../"` доказывает свойство одной промежуточной строки. Она ничего не говорит о другом separator, абсолютном пути, последующем decode или symbolic link. Надёжная граница сужает namespace на каждом шаге и поручает итоговое containment тому же filesystem lookup, который открывает объект.

## Как устроено

### Откуда приходит внешний путь

Источником бывает не только query parameter. Имя контролируется снаружи через URL wildcard, multipart filename, `Content-Disposition`, archive entry, message queue, database field, manifest, object-storage key, symlink внутри writable directory или конфигурацию другого service.

Опасные sinks шире `ReadFile`: create, overwrite, append, rename, chmod, delete, archive extract, executable/library load и template include. Последствия зависят от прав процесса: чтение secret, cross-tenant disclosure, подмена configuration, запись executable content, удаление данных или availability incident. [[10 Основы CS/Файловая система и буферизация|Модель файловой системы]] объясняет, почему одно имя может пройти через links и mount points к другому объекту.

### Сначала уменьшить namespace

Когда допустимый набор файлов известен, client передаёт `report_id`, а server хранит mapping:

```text
"rpt_7F2" -> tenant=t1, object_key=reports/2026/q1.pdf
```

Client не выражает directory structure, extension и storage location. Mapping одновременно даёт место для tenant ownership, retention state и authorization. CWE-22 прямо рекомендует такое отображение fixed input values в реальные filenames, когда набор объектов ограничен.

Если относительные подпути нужны по domain semantics, контракт задаёт их grammar: slash-separated segments, максимальные длина/глубина, допустимые characters и отсутствие empty, `.` и `..` segments. Filename из upload metadata обычно сохраняют только как display name; storage name генерирует server.

### Decode один раз и проверять внутреннее представление

Validation выполняют после того, как transport layer произвёл предусмотренное protocol decoding, но до преобразования в filesystem path. Повторный percent- или form-decode после проверки способен превратить ранее безобидные characters в separator или `..`; CWE-22 отдельно требует canonicalize before validation и не декодировать вход повторно.

Parser и opener должны видеть одно представление. На Windows учитывают `\`, volume names, UNC paths, device/reserved names и platform-specific normalization. Переносимая allowlist логических slash-paths проще, чем попытка перечислить все запрещённые OS forms.

### Лексическая локальность

В Go `filepath.IsLocal` появился в Go 1.20. Он **только лексически** проверяет, что path непустой, не абсолютный, остаётся в subtree текущего directory и на Windows не является reserved name. `filepath.Localize`, добавленный в Go 1.23, принимает slash-separated имя, допустимое по `io/fs.ValidPath`, и безопасно преобразует его в OS path либо возвращает ошибку.

Это хороший слой для logical path, но не proof реального объекта. Лексический `a/current/report.pdf` остаётся local, даже если `current` — symlink наружу. `filepath.Clean` тоже лишь нормализует строку; `filepath.Join(base, input)` не запрещает filesystem следовать links.

Строковая проверка prefix особенно хрупка:

```text
allowed root: /srv/data
candidate:    /srv/data-archive/private.txt
```

`strings.HasPrefix(candidate, root)` вернёт true, хотя candidate не descendant. Сравнение path components после canonicalization исправляет этот частный случай, но не гонку между check и use.

### Filesystem containment и TOCTOU

Последовательность `EvalSymlinks -> compare with root -> Open(path)` содержит time-of-check/time-of-use window. После проверки другой actor может заменить directory component на symlink; `Open` тогда разрешит уже другой объект. Это особенно важно для upload/extract directories, которыми может писать другой process, container или tenant.

Нужна directory-relative операция, где kernel ограничивает resolution во время самого open. В Linux 5.6 `openat2(2)` добавил `resolve` flags для untrusted paths:

- `RESOLVE_BENEATH` запрещает успешное разрешение component вне descendant tree указанного `dirfd`;
- `RESOLVE_IN_ROOT` трактует `dirfd` как root на время lookup;
- `RESOLVE_NO_SYMLINKS` запрещает symbolic links во всех components, а не только в basename;
- `RESOLVE_NO_XDEV` при необходимости запрещает пересечение mount points.

Конкретный набор зависит от semantics. Если symlinks не нужны, запретить их проще. Если нужны, containment всё равно должно обеспечиваться атомарным anchored lookup, а link targets — оставаться внутри policy root. На других OS выбирают эквивалентный handle-relative API или изолированный filesystem namespace. Предварительный canonical path остаётся диагностикой, но не security boundary.

Для переносимого Go-кода `os.Root` и `os.OpenInRoot`, добавленные в Go 1.24, задают операции относительно root и отклоняют выход через `..` или symlink. Это не эквивалент `RESOLVE_NO_SYMLINKS`: ссылка, которая остаётся внутри root, допустима. Эта версионная граница критична для безопасности. В Go 1.26.0–1.26.4 на Unix финальный symlink с завершающим `/` мог вывести `os.Root` наружу; GO-2026-4970/CVE-2026-39822 исправлена в Go 1.26.5. Поэтому на ветке Go 1.26 для такого security boundary нужна версия не ниже 1.26.5. Документация также прямо предупреждает, что `os.Root` на `GOOS=js` уязвим к TOCTOU при проверке symlinks и не гарантирует containment.

### Authorization и tenant boundary

Directory root не должен вычисляться из client-supplied tenant ID. Сначала [[20 Бэкенд/Аутентификация и авторизация на уровне API|аутентифицированный principal]] связывается с tenant и object metadata, затем server выбирает root/handle. Проверка `path is under /srv/tenants` разрешила бы tenant `t1` читать `/srv/tenants/t2`; containment и authorization отвечают на разные вопросы.

Проверяют и operation: право download не означает право overwrite или delete. Для write используют server-generated basename, временный файл в целевом directory, restrictive mode и atomic rename с явной overwrite policy. Ошибки наружу не раскрывают absolute server paths.

### Архивы и рекурсивные операции

Archive entry — тот же внешний path, только много раз в одном request. Каждое имя проходит отдельную lexical и filesystem policy; symlink/hard-link entries либо запрещают, либо обрабатывают по явному формату. Проверить только имя archive file недостаточно.

Containment также не ограничивает стоимость распаковки. Число entries, суммарные compressed/uncompressed bytes, depth и disk quota относятся к [[20 Бэкенд/Ограничения размера входных данных и исчерпание ресурсов|ресурсным лимитам]]. Recursive delete/copy дополнительно требует policy для links, mounts и смены дерева во время обхода.

## Пример или трассировка

Service отдаёт отчёты tenant `t1`. После authorization он открывает trusted directory handle для `/srv/reports/tenant-t1`. API принимает логический slash-path, максимум четыре segment, и не разрешает symlinks.

| Вход | Лексическая проверка | Filesystem lookup | Результат |
| --- | --- | --- | --- |
| `2026/q1.pdf` | valid local path | anchored open находит обычный file под `dirfd` | `200`, содержимое отчёта |
| `../private/plan.txt` | `..` делает path нелокальным | не запускается | `400 invalid_path` |
| `/srv/reports/tenant-t2/q1.pdf` | absolute path запрещён | не запускается | `400 invalid_path` |
| `2026/current/q1.pdf`, где `current` — symlink наружу | строка лексически local | `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS` отклоняет lookup | generic `404`, без утечки target |

Ключевой наблюдаемый результат: допустимость первой строки подтверждается двумя разными инвариантами — logical grammar и anchored filesystem resolution. Третья строка не получает доступ к `tenant-t2`, а четвертая показывает, почему одного `IsLocal` недостаточно.

Эта трассировка проверена по контрактам `filepath.IsLocal`/`Localize` в документации Go 1.26.5 и `openat2(2)` Linux man-pages 6.18. Исполняемый Go-пример локально не запускался: toolchain Go в среде отсутствует, поэтому статус опирается на первичные API contracts, а не на непроверенный platform-specific wrapper.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Linux до 5.6 → Linux 5.6 | `openat(2)` не имел общего набора per-open resolution restrictions | `openat2(2)` добавил `RESOLVE_BENEATH`, `RESOLVE_IN_ROOT` и другие flags | Containment untrusted path можно обеспечить во время одного kernel lookup | `openat2(2)` |
| Go до 1.20 → Go 1.20 | Для проверки lexical locality требовалась собственная логика | Появился `filepath.IsLocal` | Стандартная библиотека покрывает platform-specific lexical cases, но не symlinks | Go 1.20 release notes |
| Go до 1.23 → Go 1.23 | `FromSlash` только заменял separators | Появился `filepath.Localize`, принимающий `io/fs.ValidPath` | Slash-path из protocol можно преобразовать в OS path с проверкой representability | Go 1.23 release notes |
| Go до 1.24 → Go 1.24 | Traversal-resistant open требовал platform-specific или внешнего API | Появились `os.Root` и `os.OpenInRoot` | Portable code получил filesystem boundary относительно root | Go `os` docs 1.26.5 |
| Go 1.26.0–1.26.4 → Go 1.26.5 | На Unix финальный symlink с завершающим `/` мог вывести операцию `os.Root` за root | Исправлена GO-2026-4970/CVE-2026-39822 | `os.Root` как security boundary на ветке 1.26 требует версии не ниже 1.26.5 | Go vulnerability database |

## Trade-offs

### Opaque ID или client-visible path

ID резко сужает namespace, скрывает storage layout и удобно связывается с ownership. Он требует metadata lookup и migration при перемещении объектов. Path удобен для repositories и virtual filesystems, но переносит grammar, portability и containment в публичный contract. Для обычного download/upload API предпочтителен ID.

### Lexical validation или anchored open

Lexical check дешёв, переносим и даёт понятную `400` до I/O. Он не видит symlinks, mounts и races. Anchored handle-relative open доказывает итоговый lookup, но platform-specific и сложнее тестируется. На writable/untrusted tree нужны оба слоя; на immutable packaged assets lexical layer плюс process isolation может быть достаточным только после явного threat-model решения.

### Запретить или разрешить symlinks

Запрет упрощает invariant и снижает surprise. Разрешение сохраняет deployment conventions и deduplication, но требует containment-aware lookup для каждого component и ясной mount/link policy. Не включают `NO_SYMLINKS` глобально без разбора: Linux manual отмечает, что это ломает легитимные paths; security-sensitive user tree — отдельный случай, где строгий запрет оправдан.

### Filesystem sandbox или application check

Sandbox, отдельный mount namespace и least-privileged process уменьшают blast radius даже при ошибке path validation. Они не дают tenant-level authorization внутри общего allowed tree. Application policy и OS isolation дополняют друг друга.

## Типичные ошибки

### Удаляют `../` из строки

- **Неверное предположение:** traversal имеет одну сигнатуру.
- **Симптом:** alternate separator, absolute path или повторное decode обходят filter.
- **Причина:** denylist работает с одним representation и не задаёт допустимую grammar.
- **Исправление:** decode один раз, allowlist логических segments, `IsLocal`/`Localize`, затем anchored open.

### Проверяют `HasPrefix` после `Join`

- **Неверное предположение:** строковый prefix совпадает с descendant relation.
- **Симптом:** соседний `/srv/data-archive` принимается за `/srv/data` либо platform normalization меняет сравнение.
- **Причина:** сравниваются characters, а не path components и итоговый filesystem object.
- **Исправление:** component-aware lexical check и directory-relative filesystem lookup.

### Разрешают symlink после предварительного `EvalSymlinks`

- **Неверное предположение:** canonical path не изменится до `Open`.
- **Симптом:** редкий cross-boundary access только при параллельной замене entries.
- **Причина:** TOCTOU между check и use.
- **Исправление:** атомарное anchored resolution; иначе immutable trusted tree и OS isolation как явно задокументированное предусловие.

### Смешивают containment и authorization

- **Неверное предположение:** всё внутри общего root доступно вошедшему пользователю.
- **Симптом:** cross-tenant read/write без выхода из каталога приложения.
- **Причина:** проверено расположение, но не ownership и operation capability.
- **Исправление:** server-side object metadata, tenant binding и authorization непосредственно перед effect.

### Доверяют filename из upload или archive

- **Неверное предположение:** basename — безопасная metadata.
- **Симптом:** overwrite, hidden file, link escape или запись в неожиданное место.
- **Причина:** внешнее display name стало storage locator.
- **Исправление:** server-generated storage name; для каждого archive entry — отдельная path, link и resource policy.

## Когда применять

На design review ищут поток `external name -> filesystem sink`, включая косвенные значения из database, queue и archive. Для каждого sink фиксируют: кто выбирает root, какой logical grammar допустим, сколько раз выполняется decode, разрешены ли links/mounts, чем обеспечено atomic containment, как проверяются tenant и operation, какие права есть у process.

Практическое правило: если безопасность аргументируют фразой «после `Clean` путь начинается с base directory», доказательство ещё не завершено. Нужно показать, какой filesystem object откроется при symlink, race и platform-specific path, и почему principal имеет право именно на этот объект.

## Источники

- [CWE-22: Improper Limitation of a Pathname to a Restricted Directory](https://cwe.mitre.org/data/definitions/22.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [CWE-367: Time-of-check Time-of-use Race Condition](https://cwe.mitre.org/data/definitions/367.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [Path Traversal](https://owasp.org/www-community/attacks/Path_Traversal) — OWASP Foundation, актуальная веб-версия, проверено 2026-07-18.
- [Package filepath](https://pkg.go.dev/path/filepath@go1.26.5) — Go project, документация standard library Go 1.26.5; `IsLocal` добавлен в Go 1.20, `Localize` — в Go 1.23, проверено 2026-07-18.
- [Package os: Root](https://pkg.go.dev/os@go1.26.5#Root) — Go project, документация standard library Go 1.26.5; `Root` добавлен в Go 1.24, проверено 2026-07-18.
- [GO-2026-4970: os.Root follows symlink with trailing slash outside root](https://pkg.go.dev/vuln/GO-2026-4970) — Go vulnerability database, GO-2026-4970/CVE-2026-39822 от 2026-07-07; исправлено в Go 1.26.5, проверено 2026-07-18.
- [Go Release History](https://go.dev/doc/devel/release) — Go project, Go 1.26.5 выпущен 2026-07-07, проверено 2026-07-18.
- [Go 1.20 Release Notes](https://go.dev/doc/go1.20) — Go project, Go 1.20, проверено 2026-07-18.
- [Go 1.23 Release Notes](https://go.dev/doc/go1.23) — Go project, Go 1.23, проверено 2026-07-18.
- [openat2(2)](https://man7.org/linux/man-pages/man2/openat2.2.html) — Linux man-pages project, man-pages 6.18; syscall доступен с Linux 5.6, проверено 2026-07-18.
