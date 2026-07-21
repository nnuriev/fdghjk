---
aliases:
  - "Теоретический вопрос: Search index"
tags:
  - область/данные
  - тема/выбор-хранилища
  - тип/вопрос
статус: проверено
---

# Search index

## Вопрос

Объясните тему «Search index»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Search index заранее разворачивает документы в структуры, удобные для поиска: term dictionary и postings отвечают «в каких документах встречается term», positions поддерживают phrase/proximity, DocValues — sorting и faceting, отдельные point/vector structures — ranges и nearest-neighbor search. Query не сканирует исходный текст, а пересекает и ранжирует подготовленные списки.

Этот выигрыш оплачивается второй копией данных, analyzer contract, refresh lag, merges и восстановлением индекса. Поэтому search index обычно производен от canonical store: потерянный или испорченный индекс можно перестроить, а бизнес-инварианты остаются в primary database.

Полный разбор: [[30 Данные/Search index|Search index]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Avito.ru / classified — публикация объявления, карточка, SERP, изображения и асинхронная индексация. База: read-heavy content, поиск, search index, файловое хранилище.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].
- «SERP — нужно исходное условие; база: Проектирование поиска и автодополнения, Search index.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [Lucene index package](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/package-summary.html) — Apache Lucene, версия 10.3.1, postings, segments, stored fields, DocValues и points, проверено 2026-07-18.
- [IndexWriter](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/IndexWriter.html) — Apache Lucene, версия 10.3.1, update, commit и merge lifecycle, проверено 2026-07-18.
- [DirectoryReader](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/index/DirectoryReader.html) — Apache Lucene, версия 10.3.1, point-in-time view и refresh, проверено 2026-07-18.
- [BM25Similarity](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/search/similarities/BM25Similarity.html) — Apache Lucene, версия 10.3.1, проверено 2026-07-18.
- [Analyzer](https://lucene.apache.org/core/10_3_1/core/org/apache/lucene/analysis/Analyzer.html) — Apache Lucene, версия 10.3.1, проверено 2026-07-18.
