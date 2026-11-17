# Проверка первой версии — 10 октября 2026

- Синтаксический разбор всех пяти Swift-файлов: успешно (`swiftc -frontend -parse`). Это не проверка типов UIKit и SwiftUI.
- Структура `project.pbxproj`: успешно (`plutil -lint`).
- XML общей схемы `PhotoToPDF.xcscheme`: успешно (`xmllint --noout`).
- Модуль PDFExport и AppFailure скомпилирован локальным Swift для macOS; `PDFSmoke.swift` выполнен успешно.
- Создан и повторно открыт PDF на 240 страниц из синтетического JPEG, количество страниц подтверждено Core Graphics.
- При отсутствующем входном JPEG экспорт завершается ошибкой, итоговый и временный частичный PDF отсутствуют.

Повторение проверки PDF без полного Xcode (достаточно совместимых Command Line Tools):

```sh
swiftc -module-cache-path /tmp/PhotoToPDF-module-cache -parse-as-library PhotoToPDF/AppFailure.swift PhotoToPDF/PDFExport.swift PDFSmoke.swift -o /tmp/PhotoToPDF-pdf-smoke
/tmp/PhotoToPDF-pdf-smoke
```

Не выполнено: полная iOS-сборка, запуск в симуляторе, съёмка на iPhone, проверка восстановления сессии и меню сохранения на устройстве, замер памяти на 200+ реальных фотографиях. Полный Xcode не найден, `xcodebuild` сообщает, что активен только Command Line Tools. Приложение на iPhone не установлено и подпись не создана.


## Версия 1.1 — 24 октября 2026

Полная сборка для iPhone прошла. На симуляторе iOS 27 выполнен отдельный SessionSmoke: экспорт двух страниц, очистка всех JPEG, сохранность PDF, восстановление пустого комплекта после нового создания PageStore, второй комплект из одной страницы, история трёх PDF включая старый формат без метаданных. Все проверки прошли. Автопереход после отправки использует completionWithItemsHandler и флаг completed; доставка получателю не проверяется. Реальное завершение отправки и отмена меню требуют проверки на телефоне.
