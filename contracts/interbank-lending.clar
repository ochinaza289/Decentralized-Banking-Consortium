;; INTERBANK-LENDING CONTRACT
;; Automated interbank lending and liquidity management
;; Part of: Decentralized banking consortium for cross-institutional collaboration and risk sharing.

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_FUNDS (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_LOAN_NOT_FOUND (err u103))
(define-constant ERR_ALREADY_EXISTS (err u104))
(define-constant ERR_INVALID_COLLATERAL_RATIO (err u105))

;; Minimum collateral ratio (150%)
(define-constant MIN_COLLATERAL_RATIO u150)
;; Interest rate per block (0.01% = 1 basis point)
(define-constant INTEREST_RATE_PER_BLOCK u1)
;; Maximum loan amount
(define-constant MAX_LOAN_AMOUNT u1000000000000)

;; Data Variables
(define-data-var total-deposited uint u0)
(define-data-var total-borrowed uint u0)
(define-data-var next-loan-id uint u1)
(define-data-var protocol-fee-rate uint u50) ;; 0.5%

;; Data Maps
(define-map user-deposits principal uint)
(define-map user-borrowed principal uint)
(define-map loan-details uint {
    borrower: principal,
    amount: uint,
    collateral: uint,
    interest-rate: uint,
    start-block: uint,
    last-updated: uint
})
(define-map collateral-balances principal uint)
(define-map authorized-tokens principal bool)

;; Public Functions

;; Deposit STX to the lending pool
(define-public (deposit-stx (amount uint))
    (let ((current-balance (default-to u0 (map-get? user-deposits tx-sender))))
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set user-deposits tx-sender (+ current-balance amount))
        (var-set total-deposited (+ (var-get total-deposited) amount))
        (ok amount)
    )
)

;; Withdraw deposited STX
(define-public (withdraw-stx (amount uint))
    (let ((user-balance (default-to u0 (map-get? user-deposits tx-sender))))
        (asserts! (>= user-balance amount) ERR_INSUFFICIENT_FUNDS)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (map-set user-deposits tx-sender (- user-balance amount))
        (var-set total-deposited (- (var-get total-deposited) amount))
        (ok amount)
    )
)

;; Borrow STX against collateral
(define-public (borrow-stx (amount uint) (collateral-amount uint))
    (let (
        (loan-id (var-get next-loan-id))
        (current-borrowed (default-to u0 (map-get? user-borrowed tx-sender)))
        (current-collateral (default-to u0 (map-get? collateral-balances tx-sender)))
        (total-collateral (+ current-collateral collateral-amount))
        (total-loan (+ current-borrowed amount))
        (collateral-ratio (/ (* total-collateral u100) total-loan))
    )
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (> collateral-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (<= amount MAX_LOAN_AMOUNT) ERR_INVALID_AMOUNT)
        (asserts! (>= collateral-ratio MIN_COLLATERAL_RATIO) ERR_INVALID_COLLATERAL_RATIO)
        
        ;; Transfer collateral from user to contract
        (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
        
        ;; Transfer loan amount to user
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        
        ;; Update records
        (map-set user-borrowed tx-sender total-loan)
        (map-set collateral-balances tx-sender total-collateral)
        (map-set loan-details loan-id {
            borrower: tx-sender,
            amount: amount,
            collateral: collateral-amount,
            interest-rate: INTEREST_RATE_PER_BLOCK,
            start-block: block-height,
            last-updated: block-height
        })
        
        (var-set next-loan-id (+ loan-id u1))
        (var-set total-borrowed (+ (var-get total-borrowed) amount))
        (ok loan-id)
    )
)

;; Repay loan
(define-public (repay-loan (loan-id uint) (amount uint))
    (let (
        (loan-data (unwrap! (map-get? loan-details loan-id) ERR_LOAN_NOT_FOUND))
        (borrower (get borrower loan-data))
        (loan-amount (get amount loan-data))
        (start-block (get start-block loan-data))
        (last-updated (get last-updated loan-data))
        (blocks-elapsed (- block-height last-updated))
        (interest-amount (calculate-interest loan-amount blocks-elapsed))
        (total-owed (+ loan-amount interest-amount))
        (current-borrowed (default-to u0 (map-get? user-borrowed tx-sender)))
    )
        (asserts! (is-eq tx-sender borrower) ERR_UNAUTHORIZED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (<= amount total-owed) ERR_INVALID_AMOUNT)
        
        ;; Transfer repayment from user to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update loan details
        (if (>= amount total-owed)
            ;; Full repayment
            (begin
                (map-delete loan-details loan-id)
                (map-set user-borrowed tx-sender (- current-borrowed loan-amount))
                (var-set total-borrowed (- (var-get total-borrowed) loan-amount))
            )
            ;; Partial repayment
            (map-set loan-details loan-id (merge loan-data {
                amount: (- total-owed amount),
                last-updated: block-height
            }))
        )
        (ok amount)
    )
)

;; Liquidate undercollateralized loan
(define-public (liquidate-loan (loan-id uint))
    (let (
        (loan-data (unwrap! (map-get? loan-details loan-id) ERR_LOAN_NOT_FOUND))
        (borrower (get borrower loan-data))
        (loan-amount (get amount loan-data))
        (collateral-amount (get collateral loan-data))
        (start-block (get start-block loan-data))
        (blocks-elapsed (- block-height start-block))
        (interest-amount (calculate-interest loan-amount blocks-elapsed))
        (total-owed (+ loan-amount interest-amount))
        (collateral-ratio (/ (* collateral-amount u100) total-owed))
        (current-collateral (default-to u0 (map-get? collateral-balances borrower)))
        (current-borrowed (default-to u0 (map-get? user-borrowed borrower)))
    )
        (asserts! (< collateral-ratio MIN_COLLATERAL_RATIO) ERR_INVALID_COLLATERAL_RATIO)
        
        ;; Transfer collateral to liquidator
        (try! (as-contract (stx-transfer? collateral-amount tx-sender tx-sender)))
        
        ;; Clear loan
        (map-delete loan-details loan-id)
        (map-set collateral-balances borrower (- current-collateral collateral-amount))
        (map-set user-borrowed borrower (- current-borrowed loan-amount))
        (var-set total-borrowed (- (var-get total-borrowed) loan-amount))
        
        (ok collateral-amount)
    )
)

;; Admin function to set protocol fee rate
(define-public (set-protocol-fee-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (<= new-rate u1000) ERR_INVALID_AMOUNT) ;; Max 10%
        (var-set protocol-fee-rate new-rate)
        (ok new-rate)
    )
)

;; Read-only Functions

;; Calculate interest for a given amount and blocks
(define-read-only (calculate-interest (principal-amount uint) (blocks uint))
    (/ (* principal-amount INTEREST_RATE_PER_BLOCK blocks) u10000)
)

;; Get user deposit balance
(define-read-only (get-user-deposits (user principal))
    (default-to u0 (map-get? user-deposits user))
)

;; Get user borrowed amount
(define-read-only (get-user-borrowed (user principal))
    (default-to u0 (map-get? user-borrowed user))
)

;; Get user collateral balance
(define-read-only (get-collateral-balance (user principal))
    (default-to u0 (map-get? collateral-balances user))
)

;; Get loan details
(define-read-only (get-loan-details (loan-id uint))
    (map-get? loan-details loan-id)
)

;; Get total protocol stats
(define-read-only (get-protocol-stats)
    {
        total-deposited: (var-get total-deposited),
        total-borrowed: (var-get total-borrowed),
        next-loan-id: (var-get next-loan-id),
        protocol-fee-rate: (var-get protocol-fee-rate)
    }
)

;; Check if collateral ratio is healthy
(define-read-only (is-healthy-loan (loan-id uint))
    (match (map-get? loan-details loan-id)
        loan-data (let (
            (loan-amount (get amount loan-data))
            (collateral-amount (get collateral loan-data))
            (start-block (get start-block loan-data))
            (blocks-elapsed (- block-height start-block))
            (interest-amount (calculate-interest loan-amount blocks-elapsed))
            (total-owed (+ loan-amount interest-amount))
            (collateral-ratio (/ (* collateral-amount u100) total-owed))
        )
            (>= collateral-ratio MIN_COLLATERAL_RATIO)
        )
        false
    )
)

;; Get utilization rate
(define-read-only (get-utilization-rate)
    (let (
        (total-dep (var-get total-deposited))
        (total-bor (var-get total-borrowed))
    )
        (if (is-eq total-dep u0)
            u0
            (/ (* total-bor u10000) total-dep)
        )
    )
)

