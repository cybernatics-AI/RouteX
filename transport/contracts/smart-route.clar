;; Enhanced Nigeria Public Transportation Smart Contract

;; Define constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-invalid-input (err u105))

;; Define data maps
(define-map balances principal uint)
(define-map bus-locations uint (tuple (latitude int) (longitude int) (route-id uint) (capacity uint) (passengers uint)))
(define-map ride-tokens uint (tuple (value uint) (owner principal) (used bool) (expiry uint)))
(define-map loyalty-points principal uint)
(define-map routes uint (tuple (name (string-ascii 50)) (stops (list 20 uint))))
(define-map bus-operators principal bool)
(define-map proposals uint (tuple (description (string-ascii 500)) (votes-for uint) (votes-against uint) (status (string-ascii 20)) (deadline uint)))

;; Define variables
(define-data-var token-id-nonce uint u0)
(define-data-var carbon-credits uint u0)
(define-data-var proposal-id-nonce uint u0)
(define-data-var base-fare uint u10) ;; Base fare in STX tokens

;; Token functions
(define-public (mint-ride-token (value uint) (expiry uint))
    (let
        ((new-id (+ (var-get token-id-nonce) u1)))
        (asserts! (>= value (var-get base-fare)) err-invalid-input)
        (asserts! (> expiry block-height) err-invalid-input)
        (try! (stx-transfer? value tx-sender (as-contract tx-sender)))
        (map-set ride-tokens new-id {value: value, owner: tx-sender, used: false, expiry: expiry})
        (var-set token-id-nonce new-id)
        (ok new-id)))

(define-public (transfer-ride-token (token-id uint) (recipient principal))
    (let ((token (unwrap! (map-get? ride-tokens token-id) err-not-found)))
        (asserts! (is-eq (get owner token) tx-sender) err-unauthorized)
        (asserts! (not (get used token)) err-invalid-input)
        (asserts! (> (get expiry token) block-height) err-invalid-input)
        (map-set ride-tokens token-id (merge token {owner: recipient}))
        (ok true)))

(define-public (use-ride-token (token-id uint) (bus-id uint))
    (let
        ((token (unwrap! (map-get? ride-tokens token-id) err-not-found))
         (bus (unwrap! (map-get? bus-locations bus-id) err-not-found)))
        (asserts! (is-eq (get owner token) tx-sender) err-unauthorized)
        (asserts! (not (get used token)) err-invalid-input)
        (asserts! (> (get expiry token) block-height) err-invalid-input)
        (asserts! (< (get passengers bus) (get capacity bus)) err-invalid-input)
        (map-set ride-tokens token-id (merge token {used: true}))
        (map-set bus-locations bus-id (merge bus {passengers: (+ (get passengers bus) u1)}))
        (try! (add-loyalty-points tx-sender u1))
        (try! (add-carbon-credits u1))
        (ok true)))

;; Bus management functions
(define-public (register-bus (bus-id uint) (route-id uint) (capacity uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? bus-locations bus-id)) err-already-exists)
        (map-set bus-locations bus-id {latitude: 0, longitude: 0, route-id: route-id, capacity: capacity, passengers: u0})
        (ok true)))

(define-public (update-bus-location (bus-id uint) (latitude int) (longitude int))
    (let ((bus (unwrap! (map-get? bus-locations bus-id) err-not-found)))
        (asserts! (is-some (map-get? bus-operators tx-sender)) err-unauthorized)
        (map-set bus-locations bus-id (merge bus {latitude: latitude, longitude: longitude}))
        (ok true)))

(define-read-only (get-bus-info (bus-id uint))
    (map-get? bus-locations bus-id))

;; Route management functions
(define-public (add-route (route-id uint) (name (string-ascii 50)) (stops (list 20 uint)))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? routes route-id)) err-already-exists)
        (map-set routes route-id {name: name, stops: stops})
        (ok true)))

(define-read-only (get-route (route-id uint))
    (map-get? routes route-id))

;; Fare management functions
(define-public (update-base-fare (new-fare uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set base-fare new-fare)
        (ok true)))

(define-read-only (get-base-fare)
    (ok (var-get base-fare)))

;; Operator management functions
(define-public (register-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set bus-operators operator true)
        (ok true)))

(define-public (revoke-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-delete bus-operators operator)
        (ok true)))

;; Loyalty program functions
(define-public (add-loyalty-points (user principal) (points uint))
    (begin
        (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (as-contract tx-sender))) err-unauthorized)
        (map-set loyalty-points user (+ (default-to u0 (map-get? loyalty-points user)) points))
        (ok true)))

(define-public (redeem-loyalty-points (points uint))
    (let ((user-points (default-to u0 (map-get? loyalty-points tx-sender))))
        (asserts! (>= user-points points) err-insufficient-balance)
        (map-set loyalty-points tx-sender (- user-points points))
        (try! (as-contract (stx-transfer? (* points u1) tx-sender tx-sender)))
        (ok true)))

(define-read-only (get-loyalty-points (user principal))
    (ok (default-to u0 (map-get? loyalty-points user))))

;; Carbon credits function
(define-public (add-carbon-credits (amount uint))
    (begin
        (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (as-contract tx-sender))) err-unauthorized)
        (var-set carbon-credits (+ (var-get carbon-credits) amount))
        (ok true)))

(define-read-only (get-carbon-credits)
    (ok (var-get carbon-credits)))

;; DAO voting functions
(define-public (create-proposal (description (string-ascii 500)) (deadline uint))
    (let
        ((new-id (+ (var-get proposal-id-nonce) u1)))
        (asserts! (> (default-to u0 (map-get? balances tx-sender)) u0) err-unauthorized)
        (asserts! (> deadline block-height) err-invalid-input)
        (map-set proposals new-id {description: description, votes-for: u0, votes-against: u0, status: "active", deadline: deadline})
        (var-set proposal-id-nonce new-id)
        (ok new-id)))

(define-public (vote-on-proposal (proposal-id uint) (support bool))
    (let
        ((proposal (unwrap! (map-get? proposals proposal-id) err-not-found))
         (user-balance (default-to u0 (map-get? balances tx-sender))))
        (asserts! (> user-balance u0) err-unauthorized)
        (asserts! (< block-height (get deadline proposal)) err-invalid-input)
        (asserts! (is-eq (get status proposal) "active") err-invalid-input)
        (if support
            (map-set proposals proposal-id (merge proposal {votes-for: (+ (get votes-for proposal) user-balance)}))
            (map-set proposals proposal-id (merge proposal {votes-against: (+ (get votes-against proposal) user-balance)}))
        )
        (ok true)))

(define-public (finalize-proposal (proposal-id uint))
    (let
        ((proposal (unwrap! (map-get? proposals proposal-id) err-not-found)))
        (asserts! (>= block-height (get deadline proposal)) err-invalid-input)
        (asserts! (is-eq (get status proposal) "active") err-invalid-input)
        (if (> (get votes-for proposal) (get votes-against proposal))
            (map-set proposals proposal-id (merge proposal {status: "passed"}))
            (map-set proposals proposal-id (merge proposal {status: "rejected"}))
        )
        (ok true)))

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id))

;; Helper functions
(define-read-only (get-balance (account principal))
    (ok (default-to u0 (map-get? balances account))))

(define-public (deposit (amount uint))
    (begin
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set balances tx-sender (+ (default-to u0 (map-get? balances tx-sender)) amount))
        (ok true)))

(define-public (withdraw (amount uint))
    (let ((current-balance (default-to u0 (map-get? balances tx-sender))))
        (asserts! (>= current-balance amount) err-insufficient-balance)
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (map-set balances tx-sender (- current-balance amount))
        (ok true)))
        