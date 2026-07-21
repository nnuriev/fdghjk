---
aliases:
  - "Теоретический вопрос: Матрицы и grid traversal"
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тип/вопрос
статус: черновик
---

# Матрицы и grid traversal

## Вопрос

Какие координатные инварианты нужны для diagonal, transpose и общего grid traversal?

## Короткий ориентир

Матрицу рассматривают как rows с явно проверенной rectangular shape. Обход задаётся координатами `(row, column)` и bounds; diagonal sum отдельно обрабатывает общий центр, transpose меняет размер `rows×cols` на `cols×rows`, а neighbor traversal фиксирует допустимые направления и visited state.

Полные разборы:

- [[CurseHunter/7254/Бланк вопросов и заданий|CourseHunter 7254: матрицы]]

## Варианты follow-up

- Почему центр нечётной square matrix нельзя дважды учитывать в diagonal sum?
- Каковы dimensions результата transpose для rectangular matrix?
- Где хранить visited state при grid traversal?

## Варианты формулировки и происхождение

- [[CurseHunter/7254/Бланк вопросов и заданий#1. Matrix Diagonal Sum — LeetCode 1572|CourseHunter 7254, matrix diagonal]].
- [[CurseHunter/7254/Бланк вопросов и заданий#2. Transpose Matrix — LeetCode 867|CourseHunter 7254, transpose]].

## Источники

- [1572. Matrix Diagonal Sum](https://leetcode.com/problems/matrix-diagonal-sum/) — LeetCode, официальное условие, проверено 2026-07-19.
- [867. Transpose Matrix](https://leetcode.com/problems/transpose-matrix/) — LeetCode, официальное условие, проверено 2026-07-19.
- [36. Valid Sudoku](https://leetcode.com/problems/valid-sudoku/) — LeetCode, официальное условие, проверено 2026-07-19.
- [48. Rotate Image](https://leetcode.com/problems/rotate-image/) — LeetCode, официальное условие, проверено 2026-07-19.
- [54. Spiral Matrix](https://leetcode.com/problems/spiral-matrix/) — LeetCode, официальное условие, проверено 2026-07-19.
