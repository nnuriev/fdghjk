---
aliases:
  - Поисковый индекс
  - Inverted index
  - Full-text search index
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# Search index

## TL;DR

Search index заранее разворачивает документы в структуры, удобные для поиска: term dictionary и postings отвечают «в каких документах встречается term», positions поддерживают phrase/proximity, DocValues — sorting и faceting, отдельные point/vector structures — ranges и nearest-neighbor search. Query не сканирует исходный текст, а пересекает и ранжирует подготовленные списки.

Этот выигрыш оплачивается второй копией данных, analyzer contract, refresh lag, merges и восстановлением индекса. Поэтому search index обычно производен от canonical store: потерянный или испорченный индекс можно перестроить, а бизнес-инварианты остаются в primary database.

## Область применимости

Механизм привязан к Apache Lucene 10.3.1. Lucene — библиотека индексации; распределение, replicas, API и durability внешнего search service добавляет продукт поверх неё. Версия 10.3.1 использует immutable segment cores, point-in-time readers, postings, stored fields, DocValues, points и KNN vectors. Конкретная ranking formula и analyzer выбираются конфигурацией.

Lucene runtime не добавлялся в workspace. Пример ниже — детерминированная трассировка postings, проверенная по API 10.3.1; численный BM25 score намеренно не заявлен.

## Ментальная модель

Обычная запись идёт от document к fields. Inverted index меняет направление:

```text
document -> tokens
token -> ordered postings(docID, frequency, positions, ...)
```

Индекс похож на предметный указатель книги: сначала платим за его построение, потом быстро находим страницы по слову. Важное ограничение скрыто в первой стрелке. Если indexing analyzer и query analyzer по-разному трактуют регистр, морфологию или синонимы, postings корректны технически, но поиск не соответствует ожиданию пользователя.

## Как устроено

### Анализ текста

Analyzer превращает field value в token stream: tokenizer делит текст, filters нормализуют регистр, stop words, stemming или synonyms. Порядок filters меняет термы и positions, поэтому analyzer — версия публичного search contract. Его изменение часто требует reindex, а не только deploy нового query code.

### Postings и ranking

Для каждого term индекс хранит ordered documents и, в зависимости от `IndexOptions`, frequencies, positions и offsets. Boolean query пересекает/объединяет postings вместо чтения всех documents. BM25 использует document frequency, term frequency и length normalization; точный score относителен текущему corpus и настройкам, а не абсолютная бизнес-оценка.

Stored fields возвращают исходные значения по docID. DocValues раскладывают значения по field и удобны для sorting/faceting. Numeric/geo range обслуживают point structures. Ошибка модели — ждать, что одна физическая структура одинаково хорошо делает full-text relevance, exact filtering, aggregation и source retrieval.

### Segments, refresh и merge

Lucene index состоит из segments. Каждый новый segment уже содержит самостоятельный searchable index; immutable core упрощает concurrent readers. Update реализуется как insertion новой версии и deletion старой. Старые docIDs и deleted documents физически исчезают только после merge, который переписывает segments и освобождает место.

`IndexReader` видит point-in-time snapshot. Чтобы увидеть более новые writes, reader refresh-ят. Refresh search visibility и durable commit — разные события: низкий refresh interval увеличивает overhead и число мелких segments, а редкий refresh увеличивает staleness. Продукт поверх Lucene должен явно определить обе границы.

### Индекс как проекция

При отдельной primary database документ попадает в index через outbox/CDC или rebuild job. [[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox и CDC]] закрывают окно потери между commit бизнес-данных и публикацией изменения, но consumer всё равно должен переживать duplicates и out-of-order versions. Полезный контракт: stable document ID, monotonic source version, idempotent upsert и возможность полного rebuild.

## Сквозной пример

Есть три documents:

```text
d1: "timeout retry retry"
d2: "timeout"
d3: "database isolation"
```

После lowercase tokenizer основные postings выглядят так:

```text
timeout -> d1(freq=1), d2(freq=1)
retry   -> d1(freq=2)
database -> d3(freq=1)
isolation -> d3(freq=1)
```

Query `timeout AND retry` пересекает два списка и получает только `d1`; corpus text не сканируется. BM25 учтёт frequency `retry`, document length и rarity terms при сравнении нескольких candidates.

Теперь source меняет `d1` на `"timeout backoff"`. Writer добавляет новую версию и помечает старую удалённой. Уже открытый reader продолжает видеть прежний point-in-time view до refresh; после refresh query `timeout AND retry` больше не возвращает `d1`. До merge bytes старой версии могут оставаться в segments.

Наблюдаемый результат: write acknowledgment, search visibility, durable commit и освобождение disk space происходят на разных этапах. Метрика «indexing succeeded» не заменяет end-to-end lag от source version до searchable version.

## Trade-offs

### Встроенный full-text или отдельный index

PostgreSQL full-text search сохраняет transaction boundary и уменьшает число систем. Отдельный Lucene-based контур даёт richer analyzers, relevance, faceting и независимое search scaling, но приносит dual-write/CDC lag и rebuild. Для умеренного каталога встроенного поиска часто достаточно; внешняя система нужна после конкретного functional или capacity gap.

### Точность или recall

Aggressive stemming/synonyms повышают recall, но добавляют ложные совпадения. Exact keyword field сохраняет идентичность, text field оптимизирует relevance. Часто одно исходное значение индексируют несколькими способами и явно выбирают field в query.

### Refresh latency или throughput

Частый refresh делает изменения видимыми быстрее, но создаёт больше segment/reader work. Более крупные batches и редкий refresh повышают ingest efficiency ценой staleness. Merge policy отдельно балансирует search cost, write amplification и disk headroom.

## Типичные ошибки

- **Неверное предположение:** search index можно считать источником истины. **Симптом:** удалённый document появляется после restore или часть полей теряется при mapping change. **Причина:** индекс — производная проекция с asynchronous lifecycle. **Исправление:** canonical store, versioned events, delete/tombstone contract и проверяемый rebuild.
- **Неверное предположение:** одинаковая строка анализируется одинаково везде. **Симптом:** документ индексируется, но query его не находит. **Причина:** index/query analyzers дали разные tokens. **Исправление:** тестировать token streams как API, версионировать analyzer и reindex при несовместимом изменении.
- **Неверное предположение:** refresh означает durable commit. **Симптом:** документ был виден, но пропал после crash, либо commit есть, а старый reader его не видит. **Причина:** visibility и durability имеют разные границы. **Исправление:** зафиксировать semantics конкретного продукта и мониторить обе.
- **Неверное предположение:** update переписывает document на месте. **Симптом:** растут deleted docs, merge I/O и disk usage. **Причина:** immutable segments реализуют update через delete плюс insert. **Исправление:** capacity для merge, control update rate и метрики segment/deletion pressure.

## Когда применять

Search index нужен для relevance-ranked full-text, prefix/fuzzy/phrase queries, faceting, geo или vector retrieval, когда обычный B-tree и SQL predicates не выражают access pattern с нужной latency. До внедрения определяют analyzer, language policy, searchable/filterable/sortable fields, source version, допустимый lag, delete semantics и rebuild time.

Не добавляйте второй datastore ради одного простого exact lookup. [[30 Данные/Индексы и цена чтения и записи|Обычный индекс]] в primary database сохраняет атомарность и часто дешевле в эксплуатации. Если внешний search всё же нужен, проектируйте degradation: при lag или outage бизнес-запись не должна исчезать из canonical store.

## Источники

- [Lucene index package](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/package-summary.html) — Apache Lucene, версия 10.3.1, postings, segments, stored fields, DocValues и points, проверено 2026-07-18.
- [IndexWriter](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/IndexWriter.html) — Apache Lucene, версия 10.3.1, update, commit и merge lifecycle, проверено 2026-07-18.
- [DirectoryReader](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/DirectoryReader.html) — Apache Lucene, версия 10.3.1, point-in-time view и refresh, проверено 2026-07-18.
- [BM25Similarity](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/search/similarities/BM25Similarity.html) — Apache Lucene, версия 10.3.1, проверено 2026-07-18.
- [Analyzer](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/analysis/Analyzer.html) — Apache Lucene, версия 10.3.1, проверено 2026-07-18.
