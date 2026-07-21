---
aliases:
  - "Теоретический вопрос: encoding, encryption и hashing"
tags:
  - область/основы-cs
  - тема/криптография
  - тип/вопрос
статус: черновик
---

# Encoding, encryption, hashing и password storage

## Вопрос

Чем encoding отличается от encryption, чем symmetric encryption отличается от asymmetric и почему hashing не является «необратимым шифрованием»?

## Короткий ориентир

Encoding меняет representation ради хранения или передачи и не требует secret. Encryption защищает confidentiality относительно key и предполагает обратимое decryption. Symmetric scheme использует общий secret, а public-key scheme — связанную пару public/private keys; реальные протоколы могут сочетать public-key operations с authenticated symmetric encryption.

Cryptographic hash отображает сообщение в digest фиксированной длины. Digest не хранит достаточно информации для общего восстановления input, но это не делает hash разновидностью encryption. Для passwords недостаточно быстрого общего hash: нужны unique salt, специализированная password hashing scheme или KDF и настраиваемый cost factor.

Полный проверенный разбор: [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Cryptography и blockchain — `00:19:01–00:23:13`|Lunar Rails, cryptography и blockchain]]. Статус оставлен черновым: источники карточки прямо подтверждают hashing и password storage, но не задают единый нормативный контракт для всех encryption schemes.

## Варианты follow-up

- Почему Base64 не обеспечивает confidentiality?
- Зачем production protocol сочетает asymmetric и symmetric primitives?
- Почему обычный SHA-256 без salt и cost factor не подходит для хранения passwords?

## Варианты формулировки и происхождение

- «Чем encoding отличается от encryption? Чем hashing отличается от encryption?» — [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Cryptography и blockchain — `00:19:01–00:23:13`|Lunar Rails, cryptography и blockchain]].

## Источники

- [FIPS 180-4: Secure Hash Standard](https://csrc.nist.gov/pubs/fips/180-4/upd1/final) — NIST, final 2015, проверено 2026-07-18.
- [NIST SP 800-63B-4: Password Verifiers](https://pages.nist.gov/800-63-4/sp800-63b.html#passwordver) — NIST, revision 4, проверено 2026-07-18.
