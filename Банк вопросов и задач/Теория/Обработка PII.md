---
aliases:
  - "Теоретический вопрос: Обработка PII"
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/приватность
  - тип/вопрос
статус: проверено
---

# Обработка PII

## Вопрос

Как работает «Обработка PII» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

PII (personally identifiable information) нельзя надёжно определить списком полей вроде `email`, `phone` и `passport`. Идентифицируемость зависит от комбинации данных, контекста, доступных дополнительных наборов и назначения обработки. Почтовый индекс в одном отчёте даёт статистику, а в маленькой группе вместе с должностью и датой события способен выделить конкретного человека.

Backend должен управлять не «секретными колонками», а жизненным циклом обработки: зачем поле собирается, на каком основании, кому доступно, куда копируется, какие производные создаёт, сколько хранится и как удаляется. Базовый порядок такой: инвентаризировать data flow, минимизировать сбор, отделить identity от domain data, ограничить доступ по purpose, защитить transport/storage, исключить PII из telemetry и провести [[20 Бэкенд/Data retention и deletion|retention/deletion]] по всем копиям. Encryption и pseudonymisation снижают риск, но не превращают ненужные данные в нужные и обычно не выводят их из privacy scope.

Полный разбор: [[20 Бэкенд/Обработка PII|Обработка PII]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Seller/buyer IDs и message bodies — PII: encryption in transit/at rest, least privilege, retention/deletion и audit access. Модель следует обработке PII.» — [[Авито/Решения/System Design/Messenger BE#Безопасность|Авито/Решения/System Design/Messenger BE, раздел «Безопасность»]].
- «Coordinates и trip history — чувствительные PII. Data residency, retention, deletion, access audit и purpose limitation определяются per country; техническая модель следует обработке PII.» — [[Авито/Решения/System Design/Uber#Безопасность|Авито/Решения/System Design/Uber, раздел «Безопасность»]].

## Источники

- [NIST SP 800-122: Guide to Protecting the Confidentiality of Personally Identifiable Information](https://csrc.nist.gov/pubs/sp/800/122/final) — NIST, final от апреля 2010 года; определения, impact factors и safeguards для PII в федеральном контексте США, проверено 2026-07-18.
- [Regulation (EU) 2016/679 (GDPR)](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng) — European Parliament and Council, официальный текст от 2016-04-27; Articles 4, 5, 17, 25, 30 и 32, проверено 2026-07-18.
- [Guidelines 4/2019 on Article 25 Data Protection by Design and by Default](https://www.edpb.europa.eu/documents/guideline/guidelines-42019-on-article-25-data-protection-by-design-and-by-default_en) — European Data Protection Board, final version от 2020-10-20, проверено 2026-07-18.
- [Guidelines 02/2026 on Anonymisation](https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202602_anonymisation_v1_en_0.pdf) — European Data Protection Board, version 1.0, принята 2026-07-07 для public consultation до 2026-10-30; не final, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, Rev. 5, release 5.2.0 от 2025-08-27; families PT, AC, AU, SC и control SI-12, проверено 2026-07-18.
