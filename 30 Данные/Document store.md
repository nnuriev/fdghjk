---
aliases:
  - Document database
  - Документная база данных
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# Document store

## TL;DR

Document store хранит aggregate как вложенный document: поля, массивы и поддокументы читаются и часто обновляются одной операцией. Это сокращает joins и позволяет разным документам иметь разные наборы полей. Выигрыш появляется, когда граница документа совпадает с тем, что приложение читает, изменяет и архивирует вместе.

«Гибкая schema» не отменяет моделирование. Неограниченный массив, часто меняющаяся общая сущность или many-to-many связь превращают embedding в дублирование, document growth и write contention. Тогда нужны references, отдельные collections либо реляционная модель.

## Область применимости

Механизм показан на MongoDB 8.0 и BSON. В этой версии стандартный document имеет обязательный уникальный `_id`, максимальный BSON-размер 16 MiB, а отдельная write operation атомарна на уровне одного документа. Multi-document transactions поддерживаются, но их наличие не делает плохую aggregate boundary бесплатной. Другие document stores отличаются limits, query language, consistency и transaction scope.

MongoDB в локальной среде отсутствует. Фрагмент документа ниже синтаксически проверен как JavaScript object literal; MongoDB-команд в примере нет. Shape, limit и atomicity сверены с MongoDB Database Manual 8.0.

## Ментальная модель

Документ — сериализованный aggregate с собственным identity. Если экран заказа всегда требует header, delivery address и lines, их можно хранить рядом и получить одной адресацией. В реляционной модели те же факты чаще разложены по relations и собираются join-ом.

Граница документа одновременно задаёт три вещи: единицу локальности чтения, естественную границу атомарной записи и область, которая растёт как одно значение. Удачная граница помогает всем трём. Ошибка в границе бьёт сразу по всем.

## Как устроено

### BSON и schema

BSON document содержит ordered field-value pairs, включая вложенные documents и arrays. Физически гибкая форма позволяет двум documents одной collection иметь разные поля, но readers всё равно ожидают типы и обязательные значения. Schema validation, version field и backward-compatible readers нужны по той же причине, что и [[30 Данные/Миграции схемы данных|миграции схемы]] в SQL.

### Embedding

Embedding помещает связанные данные внутрь родителя. Оно выгодно, когда данные:

- читаются и обновляются вместе;
- принадлежат одному aggregate lifecycle;
- имеют ограниченный размер и cardinality;
- не требуют независимого поиска или ownership.

Одна atomic update может поменять несколько вложенных полей того же document. Это сильная причина моделировать инвариант внутри aggregate, а не разносить его по collections.

### References

Reference хранит `_id` другой сущности. Она подходит, когда child живёт самостоятельно, участвует в many-to-many, часто меняется отдельно или может расти без границы. Цена — дополнительный lookup, `$lookup`/aggregation либо сборка в приложении. Как и foreign key, reference задаёт связь, но manual reference MongoDB сама по себе не обещает ссылочную целостность.

### Индексы и write path

Document store не ищет произвольное поле магически: запросу всё равно нужен подходящий index. Каждый index занимает storage и обновляется при затрагивающей его записи, поэтому модель с десятками access paths платит write amplification. Вложенные arrays могут создавать multikey index entries; размер документа и число индексируемых элементов входят в capacity model.

## Сквозной пример

Заказ хранит snapshot товара на момент покупки:

```javascript
{
  _id: "order-42",
  customer_id: "customer-7",
  status: "paid",
  delivery: { city: "Yerevan", address: "..." },
  lines: [
    { product_id: "p-9", title: "Keyboard", unit_price: 12000, qty: 2 }
  ],
  schema_version: 2
}
```

`title` и `unit_price` встроены намеренно: invoice должен сохранить исторический snapshot, даже если catalog позднее изменится. Операция перевода `status` и добавления payment reference может быть одной atomic update этого order document.

Catalog product остаётся отдельным document по `product_id`, потому что у него собственный lifecycle и поиск. Если вместо snapshot встроить весь изменяемый product, обновление названия потребует переписать все старые заказы, что ещё и испортит историю.

Наблюдаемый результат: чтение order details не делает join, изменения одного заказа атомарны, а catalog обновляется независимо. Цена — осознанное дублирование snapshot и обязанность версионировать его форму.

## Trade-offs

### Document store или relational database

Document store выигрывает на aggregate-oriented доступе и неоднородных optional fields. Реляционная модель сильнее, когда связи many-to-many, cross-aggregate constraints и разные срезы данных важнее локальности одного object. Нормализация уменьшает дублирование; embedding уменьшает read joins. Подробный обмен разобран в [[30 Данные/Нормализация и денормализация|нормализации и денормализации]].

### Embedding или references

Embedding даёт одну read/write boundary, но увеличивает размер и contention популярного parent. Reference сохраняет независимость child и ограничивает рост parent, но добавляет round trips и consistency window. Выбор делают по cardinality, lifecycle и update frequency, а не по эстетике JSON.

### Гибкость или строгий контракт

Добавить поле без table rewrite удобно. Но mixed schema усложняет indexes, queries и rollback: reader должен понимать старые documents, пока backfill не завершён. Schema validation ловит часть ошибок раньше, чем production query.

## Типичные ошибки

- **Неверное предположение:** всё связанное нужно embed-ить. **Симптом:** document приближается к 16 MiB, updates замедляются, один parent становится hot. **Причина:** unbounded child collection попала внутрь aggregate. **Исправление:** вынести children, задать bucket/partition boundary или хранить bounded summary.
- **Неверное предположение:** flexible schema не требует migrations. **Симптом:** новый код падает на старом типе поля или index покрывает лишь часть документов. **Причина:** одновременно живут несовместимые shapes. **Исправление:** versioned reader, совместимый write path, resumable backfill и validation после convergence.
- **Неверное предположение:** reference равна foreign key. **Симптом:** ссылки ведут на удалённые documents. **Причина:** manual reference хранит идентификатор, но не поддерживает referential integrity автоматически. **Исправление:** выбрать ownership/delete protocol, transaction там, где она нужна, и reconciliation job.
- **Неверное предположение:** document store устраняет joins без цены. **Симптом:** одно изменение fan-out-ится на тысячи копий. **Причина:** read optimization превратилась в неконтролируемую денормализацию. **Исправление:** разделить immutable snapshot и mutable canonical data, измерить fan-out.

## Когда применять

Document store подходит для каталогов с разными атрибутами, content entities, configuration, profiles и aggregates, которые приложение обычно читает целиком. Перед выбором назовите identity, максимальный размер, boundedness вложенных collections, атомарный invariant, независимые access paths и schema evolution protocol.

Не выбирайте его только потому, что API принимает JSON. Если основная работа — joins через много независимых entities, строгая ссылочная целостность и ad hoc analytics, [[30 Данные/Моделирование данных и реляционная модель|реляционная модель]] обычно выражает задачу прямее. Большие binary payload лучше вынести в [[30 Данные/Object и blob storage|object/blob storage]], оставив в document metadata и key.

## Источники

- [Documents](https://www.mongodb.com/docs/v8.0/core/document/) — MongoDB, Database Manual 8.0, BSON, `_id` и limit 16 MiB, проверено 2026-07-18.
- [Embedded Data in Your MongoDB Schema](https://www.mongodb.com/docs/v8.0/tutorial/model-embedded-one-to-many-relationships-between-documents/) — MongoDB, Database Manual 8.0, проверено 2026-07-18.
- [Reference Data in Your MongoDB Schema](https://www.mongodb.com/docs/v8.0/data-modeling/referencing/) — MongoDB, Database Manual 8.0, проверено 2026-07-18.
- [MongoDB CRUD Operations](https://www.mongodb.com/docs/v8.0/crud/) — MongoDB, Database Manual 8.0, single-document atomicity, проверено 2026-07-18.
- [Transactions](https://www.mongodb.com/docs/v8.0/core/transactions/) — MongoDB, Database Manual 8.0, проверено 2026-07-18.
- [Create an Index](https://www.mongodb.com/docs/v8.0/core/indexes/create-index/) — MongoDB, Database Manual 8.0, влияние indexes на writes, проверено 2026-07-18.
