---
aliases:
  - "Теоретический вопрос: UTXO и account model"
tags:
  - область/распределённые-системы
  - тема/blockchain
  - тип/вопрос
статус: черновик
---

# UTXO, account model и Bitcoin address

## Вопрос

Чем UTXO model отличается от account-based model и что именно кодирует Bitcoin address?

## Короткий ориентир

В UTXO model transaction потребляет конкретные предыдущие outputs и создаёт новые, поэтому состояние представляется набором unspent outputs. В account model хранятся accounts, balances и nonces, а transaction применяет state transition. Разница влияет на построение transaction, доступ к состоянию и возможность параллельной проверки, но не превращает эти две модели в исчерпывающую классификацию всех ledgers.

Bitcoin address — человекочитаемое кодирование destination или payment condition с network/version и checksum semantics. Определение «hash public key» слишком узко: разные address types кодируют разные script или witness programs.

Полный проверенный разбор: [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Cryptography и blockchain — `00:19:01–00:23:13`|Lunar Rails, UTXO, account model и Bitcoin address]]. Статус оставлен черновым, потому что приведённый первичный источник полностью покрывает Bitcoin, но не является нормативным источником для всех account-based systems.

## Варианты follow-up

- Как UTXO и account model меняют поиск конфликтующих transactions?
- Почему Bitcoin address нельзя во всех случаях определить как public-key hash?
- Какие данные нужны, чтобы проверить address до отправки transaction?

## Варианты формулировки и происхождение

- «Чем UTXO model отличается от account-based model? Что такое Bitcoin address?» — [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Cryptography и blockchain — `00:19:01–00:23:13`|Lunar Rails, cryptography и blockchain]].

- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Опыт и мотивация к домену — `00:02:41–00:08:43`|Опыт и мотивация к домену — `00:02:41–00:08:43`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [Bitcoin Developer Guide: Transactions](https://developer.bitcoin.org/devguide/transactions.html) — Bitcoin Developer Documentation, UTXO и legacy address encodings, проверено 2026-07-18.
