---
aliases: []
tags:
  - тип/карта
  - область/go
статус: проверено
---

# Карта — Go

## Назначение

Отдельное направление по языку Go: семантика языка, конкурентность, runtime, backend-библиотеки и инструменты диагностики.

## Входные знания

- Опыт написания небольших программ на Go.
- Основы ОС, сетей и памяти по [[10 Основы CS/Карта — Основы CS|карте основ CS]].

## Маршрут

- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]]

## Готовые заметки

### Язык

- [[60 Go/Zero values, семантика значений и копирование]] — значения по умолчанию, value semantics и границы поверхностного копирования.
- [[60 Go/Функции, function values и замыкания]] — function types, higher-order functions, method values/expressions, closure lifetime и граница loop-variable semantics в Go 1.22.
- [[60 Go/Массивы и слайсы]] — `len`, `cap`, `append`, reslicing и aliasing общего backing array.
- [[60 Go/Map]] — отсутствие порядка, comparability ключей и ограничения concurrent access.
- [[60 Go/Строки, байты, руны и UTF-8]] — различия между `string`, `[]byte`, `[]rune` и обработка Unicode.
- [[60 Go/Структуры, указатели и методы]] — устройство structs, адресуемость, разыменование и вызов методов.
- [[60 Go/Pointer и value receivers, method sets]] — выбор receiver, копирование значения и доступность методов.
- [[60 Go/Интерфейсы и неявная реализация]] — контракт интерфейса и implicit implementation без декларации implements.
- [[60 Go/Nil, type assertions и type switches в интерфейсах]] — nil interface, интерфейс с nil pointer, assertions и type switches.
- [[60 Go/Embedding и composition]] — promotion полей и методов, композиция и её отличие от наследования.
- [[60 Go/Дженерики, constraints и type sets]] — type parameters, ограничения, type sets и вывод типов.
- [[60 Go/Обработка ошибок]] — wrapping, `errors.Is`, `errors.As`, sentinel и typed errors.
- [[60 Go/defer, panic и recover]] — порядок defer, раскрутка стека и границы безопасного recover.
- [[60 Go/Равенство и comparability типов]] — сравнимые и несравнимые типы, интерфейсы и ограничения операций равенства.
- [[60 Go/Пакеты, модули и направление зависимостей]] — package boundaries, import cycles, dependency direction, modules и workspace.

### Concurrency

- [[60 Go/Goroutines и lifecycle]] — запуск, завершение, координация и ответственность за остановку goroutine.
- [[60 Go/Буферизация, ownership и закрытие каналов]] — unbuffered и buffered channels, владелец close и receive из закрытого канала.
- [[60 Go/select, cancellation и timeout]] — ожидание нескольких событий, отмена операции и ограничение времени ожидания.
- [[60 Go/Context, deadlines и распространение отмены]] — propagation значений запроса, deadlines и cancellation через `context.Context` по дереву вызовов.
- [[60 Go/Mutex, RWMutex и примитивы координации sync]] — `Mutex`, `RWMutex`, `WaitGroup`, `Once` и `Cond`.
- [[60 Go/Пакет sync-atomic|Пакет sync/atomic]] — атомарные операции, их гарантии и область применения.
- [[60 Go/Каналы или mutex]] — выбор между передачей данных и защитой общего состояния.
- [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency]] — композиция потоков работы и ограничение параллелизма.
- [[60 Go/Backpressure]] — согласование скорости producer и consumer без неограниченного роста очередей.
- [[60 Go/Data races, deadlocks и livelocks]] — нарушения safety и liveness, их симптомы и причины.
- [[60 Go/Goroutine и channel leaks]] — незавершаемые goroutines, заблокированные операции и потерянное владение каналами.
- [[60 Go/Модель памяти Go и happens-before]] — видимость записей, synchronization events и доказательство порядка операций.

### Runtime и performance

- [[60 Go/Планировщик GMP]] — роли G, M и P, очереди выполнения и причины scheduler latency.
- [[60 Go/Стеки и escape analysis]] — рост goroutine stacks, размещение на heap и решения escape analysis.
- [[60 Go/Аллокации, GC и GC pressure]] — heap allocations, работа garbage collector и источники давления на GC.
- [[60 Go/Снижение аллокаций и sync.Pool]] — повторное использование памяти, trade-offs и негарантированное содержимое pool.
- [[60 Go/Runtime-устройство map]] — реализация map, рост, итерация и практические последствия для производительности.
- [[60 Go/Netpoller]] — ожидание сетевого I/O без блокировки M на каждую ожидающую goroutine.
- [[60 Go/Бенчмарки]] — корректная постановка benchmark, измерение allocations и интерпретация результатов.
- [[60 Go/Race detector]] — инструментальное обнаружение data races, ограничения и стоимость запуска.
- [[60 Go/Профилирование с pprof]] — CPU, memory, mutex и goroutine profiles.
- [[60 Go/Execution trace]] — временная картина scheduler, goroutines, blocking и GC.

### Backend standard library

- [[60 Go/HTTP-сервер на net-http|HTTP-сервер на net/http]] — lifecycle запроса, handlers, middleware и управление соединениями.
- [[60 Go/HTTP-клиент и Transport]] — переиспользование `Client`, устройство `Transport` и lifecycle response body.
- [[60 Go/Тайм-ауты HTTP-сервера и клиента]] — уровни timeout, deadlines и предотвращение зависших соединений.
- [[60 Go/Graceful shutdown]] — прекращение приёма запросов, ожидание in-flight работы и ограничение времени остановки.
- [[60 Go/Пакет database-sql и пулы соединений|Пакет database/sql и пулы соединений]] — lifecycle запросов, connection pool, транзакции и освобождение ресурсов.
- [[60 Go/Пакет encoding-json|Пакет encoding/json]] — marshaling, unmarshaling, tags, числа и потоковая обработка.
- [[60 Go/Пакеты io и bufio]] — интерфейсы Reader и Writer, композиция потоков и буферизация.
- [[60 Go/Пакет time, таймеры и тикеры]] — работа с duration, timers, tickers и корректная остановка ресурсов.
- [[60 Go/Тестирование и httptest]] — table-driven tests, test helpers и проверка HTTP handlers и servers.
- [[60 Go/Fuzzing]] — генерация входов, corpus, invariants и воспроизводимость найденных сбоев.

## План заметок

Содержание страниц ниже заполнено и сверено с первичными источниками, но их исполняемые Go-примеры не удалось запустить без локальной Go toolchain. До compile/test они остаются черновиками.

- [[60 Go/Table-driven tests в Go]]
- [[60 Go/Детерминированное тестирование concurrent code]]

## Связанные карты

- [[10 Основы CS/Карта — Основы CS|Основы CS]]
- [[20 Бэкенд/Карта — Бэкенд|Бэкенд]]
- [[20 Бэкенд/Карта — Testing, Debugging и Code Quality|Testing, Debugging и Code Quality]]
- [[40 Распределённые системы/Карта — Распределённые системы|Распределённые системы]]
- [[50 Проектирование систем/Карта — Low-Level Design|Low-Level Design / Object-Oriented Design]]
- [[70 Практические кейсы/Карта — Практические кейсы|Практические кейсы]]
