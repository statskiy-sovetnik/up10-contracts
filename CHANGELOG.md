# Changelog - IDOManager v2.0.0

Этот документ описывает основные архитектурные изменения между legacy `IDOManager` и новой реализацией.

---

## 1. Управление правами администратора и средствами

### **КРИТИЧНО: EmergencyWithdrawAdmin → ReservesManager**

#### Legacy система
Контракт наследовал `EmergencyWithdrawAdmin`, который позволял администратору выводить любое количество токенов в любое время без ограничений через функцию `emergencyWithdraw(address _token, uint256 _amount)`.

#### Новая система
Контракт наследует абстрактный контракт `ReservesManager`, который предоставляет четыре отдельные функции вывода с ограничениями:

1. **withdrawStablecoins(uint256 idoId, address token, uint256 amount)** - Может выводить стейблкоины только пропорционально заклейменным пользователями токенам. Формула: `netRaised * (totalClaimed / netAllocated) - alreadyWithdrawn`. Средства заблокированы графиком вестинга.

2. **withdrawUnsoldTokens(uint256 idoId)** - Может выводить непроданные токены только после окончания IDO. Рассчитывается как: `totalAllocation - totalAllocated`.

3. **withdrawRefundedTokens(uint256 idoId)** - Может выводить только токены, которые пользователи вернули через рефанд. Рассчитывается как: `totalRefunded + refundedBonus`.

4. **withdrawPenaltyFees(uint256 idoId, address stablecoin)** - Может выводить только штрафные сборы, собранные с рефандов пользователей. Отслеживается отдельно в маппинге `penaltyFeesCollected`.

**Новая роль**: `reservesAdmin` - отдельная от обычного `admin` роль, которая может выполнять только функции вывода средств с описанными выше ограничениями.

---

## 2. Изменения структур данных

### 2.1. Разделение IDO структуры

**Legacy**: Одна монолитная структура `IDO` содержала 44+ полей

**Новая версия**: Данные разделены на логические группы через отдельные маппинги:
- `mapping(uint256 => IDO) public idos` - основная информация (totalParticipants, totalRaisedUSDT, info, bonuses)
- `mapping(uint256 => IDOSchedules) public idoSchedules` - параметры времени, расписания
- `mapping(uint256 => IDORefundInfo) public idoRefundInfo` - информация о рефандах
- `mapping(uint256 => IDOPricing) public idoPricing` - ценовая информация

### 2.2. Структура IDOInput для создания IDO

**Legacy**: Плоская структура с 30+ полями, передаваемыми напрямую.

**Новая версия**: Вложенные структуры для группировки связанных данных:
- `IDOInfo info` - основная информация (projectId, tokenAddress, минимальная и максимальная аллокации)
- `IDOBonuses bonuses` - проценты бонусов для трех фаз
- `IDOSchedules schedules` - все временные параметры
- `RefundPenalties refundPenalties` - штрафы за разные типы рефандов
- `RefundPolicy refundPolicy` - политика рефандов (булевы флаги)
- `uint256 initialPriceUsdt` - начальная цена
- `uint256 fullRefundPriceUsdt` - цена для полного рефанда

### 2.3. Удаленные поля

Следующие поля были **удалены** из структуры IDO:
- `minAllocationUSDT` - конвертируется в количество токенов при создании
- `totalAllocationByUserUSDT` - конвертируется в количество токенов при создании
- `totalAllocationUSDT` - конвертируется в количество токенов при создании

**Причина**: Все лимиты аллокации, выраженные в USDT, теперь конвертируются в количество токенов при создании IDO, что исключает избыточное хранение.

### 2.4. Новая структура IDOInfo

Все поля аллокации теперь хранятся в **токенах** вместо USDT:
- `minAllocation` (в токенах)
- `totalAllocationByUser` (в токенах)
- `totalAllocation` (в токенах)

Конвертация происходит при создании IDO: `valueUSDT * PRICE_DECIMALS / initialPriceUsdt`

### 2.5. Разделение политики рефандов

**Legacy**: 9 булевых полей и одно uint64 поле были частью основной структуры IDO.

**Новая версия**: Выделены в отдельные структуры:

**RefundPolicy** (9 полей):
- `fullRefundDuration`
- `isRefundIfClaimedAllowed`
- `isRefundUnlockedPartOnly`
- `isRefundInCliffAllowed`
- `isFullRefundBeforeTGEAllowed`
- `isPartialRefundInCliffAllowed`
- `isFullRefundInCliffAllowed`
- `isPartialRefundInVestingAllowed`
- `isFullRefundInVestingAllowed`

**RefundPenalties** (3 поля):
- `fullRefundPenalty`
- `fullRefundPenaltyBeforeTge`
- `refundPenalty`

**IDORefundInfo** объединяет:
- Runtime счетчики (totalRefunded, refundedBonus, totalRefundedUSDT)
- RefundPenalties
- RefundPolicy

**Удалено**: Поле `isPartialRefundBeforeTGEAllowed` было удалено (в новой версии разрешены только полные рефанды до TGE).

### 2.6. Новые маппинги для отслеживания резервов

Добавлены маппинги для точного учета средств по каждому IDO и токену:
- `mapping(uint256 => mapping(address => uint256)) public totalRaisedInToken` - всего собрано в конкретном токене
- `mapping(uint256 => mapping(address => uint256)) public totalRefundedInToken` - всего возвращено через рефанд
- `mapping(uint256 => uint256) public totalClaimedTokens` - всего заклеймлено пользователями

**Цель**: Обеспечить точный расчет доступных для вывода администратором сумм на основе прогресса вестинга.

### 2.7. Состояние ReservesManager

Новые маппинги для аудита выводов администратора:
- `mapping(uint256 => mapping(address => uint256)) public stablecoinsWithdrawnInToken` - выведенные стейблкоины
- `mapping(uint256 => mapping(address => uint256)) public penaltyFeesCollected` - собранные штрафы
- `mapping(uint256 => uint256) public unsoldTokensWithdrawn` - выведенные непроданные токены
- `mapping(uint256 => uint256) public refundedTokensWithdrawn` - выведенные возвращенные токены
- `mapping(uint256 => mapping(address => uint256)) public penaltyFeesWithdrawn` - выведенные штрафы

---

## 3. Математические константы

**Legacy**: `uint32 private constant PERCENT_DECIMALS = 100000` (5 десятичных знаков, точность 0.001%)

**Новая версия**: `uint32 private constant HUNDRED_PERCENT = 10_000_000` (7 десятичных знаков, точность 0.00001%)

**Примечание**: В старой версии величина всегда умножалась на 100, изменений в точности нет.

---

## 5. Изменения сигнатур функций и событий

### 5.1. Событие Investment

**Legacy**: Событие содержало поле `amountToken` (сырое количество токена).

**Новая версия**: Поле `amountToken` удалено. Событие содержит: `idoId`, `investor`, `amountUsdt`, `tokenIn`, `tokensBought`, `tokensBonus`.

**Влияние на интеграцию**: Слушатели событий должны быть обновлены.

### 5.2. Безопасность переводов токенов

**Legacy**: Использовались прямые вызовы `require(IERC20(token).transfer(...), "Transfer failed")`.

**Новая версия**: Все переводы токенов используют библиотеку OpenZeppelin SafeERC20:
- `safeTransfer`
- `safeTransferFrom`

**Преимущество**: Совместимость с нестандартными ERC20 токенами (например, USDT, который не возвращает bool).

### 5.3. Сеттеры зависимостей

Функции `setKYCRegistry` и `setAdminManager` теперь:
- Помечены модификатором `override`
- Вызывают внутренние функции `_setKYCRegistry` и `_setAdminManager`, определенные в абстрактных базовых контрактах

---

## 6. Обработка ошибок

**Legacy**: Использовались строковые сообщения об ошибках в `require`.

**Новая версия**: Использование кастомных ошибок (определены в Errors.sol):
- `InvalidAmount()`
- `KYCRequired()`
- `NotAStablecoin()`
- ...

**Влияние на интеграцию**: Frontend должен обрабатывать типы кастомных ошибок вместо парсинга строк.

---

## 8. Изменения в конструкторе

**Legacy конструктор** принимал:
- `address _usdt`
- `address _usdc`
- `address _flx`
- `address _kyc`
- `address _emergencyWithdrawAdmin`
- `address _adminManager`

**Новый конструктор** принимает:
- `address _usdt`
- `address _usdc`
- `address _flx`
- `address _kyc`
- `address _reservesAdmin` (замена _emergencyWithdrawAdmin)
- `address _adminManager`
- `address _initialOwner` (новый параметр, требуется OpenZeppelin Ownable)

**Влияние на интеграцию**: Скрипты деплоя должны быть обновлены для передачи дополнительного параметра `_initialOwner`.

---

## 9. Версия компилятора Solidity

**Legacy**: `pragma solidity ^0.8.20`

**Новая версия**: `pragma solidity 0.8.30`

Изменение на точную версию (без `^`) обеспечивает детерминированную компиляцию.

---

## Критические изменения (Breaking Changes)

1. **EmergencyWithdrawAdmin → ReservesManager** - критическое изменение безопасности с ограничениями вывода
2. **Структура IDO разделена** на отдельные маппинги - изменение паттерна чтения данных
3. **IDOInput теперь использует вложенные структуры** - изменение паттерна записи данных
4. **Поля аллокации теперь в токенах** вместо USDT
5. **Удалено поле из события Investment** (amountToken)
6. **Кастомные ошибки** вместо строковых сообщений
7. **Параметры конструктора** для инъекции зависимостей (включая initialOwner)
8. **Библиотеки OpenZeppelin** заменяют кастомные реализации
9. **Удалено поле** isPartialRefundBeforeTGEAllowed из политики рефандов

---

**Версия**: 2.0.0
**Дата**: 2025-11-23
**Компилятор**: Solidity 0.8.30 (обновление с 0.8.20)
