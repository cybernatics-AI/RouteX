;; Complete Nigeria Public Transportation Smart Contract

;; Define constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-already-exists (err u104))
(define-constant err-invalid-input (err u105))

;; Constants for input validation
(define-constant max-latitude 90)
(define-constant min-latitude -90)
(define-constant max-longitude 180)
(define-constant min-longitude -180)
(define-constant max-capacity u100)
(define-constant max-route-stops u20)

;; Constants for pricing
(define-constant max-multiplier u500) ;; Maximum 5x multiplier (500%)
(define-constant min-multiplier u50)  ;; Minimum 0.5x multiplier (50%)

;; Define data maps
(define-map balances principal uint)
(define-map bus-locations uint (tuple (latitude int) (longitude int) (route-id uint) (capacity uint) (passengers uint)))
(define-map ride-tokens uint (tuple (value uint) (owner principal) (used bool) (expiry uint)))
(define-map loyalty-points principal uint)
(define-map routes uint (tuple (name (string-ascii 50)) (stops (list 20 uint))))
(define-map bus-operators principal bool)
(define-map proposals uint (tuple (description (string-ascii 500)) (votes-for uint) (votes-against uint) (status (string-ascii 20)) (deadline uint)))
(define-map time-multipliers uint uint)
(define-map demand-multipliers uint uint)
(define-map special-event-multipliers uint uint)

;; Define variables
(define-data-var token-id-nonce uint u0)
(define-data-var carbon-credits uint u0)
(define-data-var proposal-id-nonce uint u0)
(define-data-var base-fare uint u10) ;; Base fare in STX tokens

;; Token functions
(define-public (mint-ride-token (expiry uint) (hour uint) (demand-level uint) (special-event-id (optional uint)))
    (let
        ((new-id (+ (var-get token-id-nonce) u1))
         (base-price (var-get base-fare))
         (dynamic-price (unwrap! (calculate-fare base-price hour demand-level special-event-id) err-invalid-input)))
        (asserts! (> expiry block-height) err-invalid-input)
        (asserts! (< hour u24) err-invalid-input)
        (asserts! (< demand-level u5) err-invalid-input)
        (match special-event-id
            event-id (asserts! (and (is-some (map-get? special-event-multipliers event-id)) 
                                    (<= event-id u1000))  ;; Add a reasonable upper limit for event IDs
                               err-invalid-input)
            true)
        (try! (stx-transfer? dynamic-price tx-sender (as-contract tx-sender)))
        (map-set ride-tokens new-id {value: dynamic-price, owner: tx-sender, used: false, expiry: expiry})
        (var-set token-id-nonce new-id)
        (ok new-id)))

(define-public (transfer-ride-token (token-id uint) (recipient principal))
    (let ((token (unwrap! (map-get? ride-tokens token-id) err-not-found)))
        (asserts! (is-eq (get owner token) tx-sender) err-unauthorized)
        (asserts! (not (get used token)) err-invalid-input)
        (asserts! (> (get expiry token) block-height) err-invalid-input)
        (asserts! (not (is-eq recipient tx-sender)) err-invalid-input)
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
        (asserts! (is-some (map-get? routes route-id)) err-not-found)
        (asserts! (<= capacity max-capacity) err-invalid-input)
        (map-set bus-locations bus-id {latitude: 0, longitude: 0, route-id: route-id, capacity: capacity, passengers: u0})
        (ok true)))

(define-public (update-bus-location (bus-id uint) (latitude int) (longitude int))
    (let ((bus (unwrap! (map-get? bus-locations bus-id) err-not-found)))
        (asserts! (is-some (map-get? bus-operators tx-sender)) err-unauthorized)
        (asserts! (and (>= latitude min-latitude) (<= latitude max-latitude)) err-invalid-input)
        (asserts! (and (>= longitude min-longitude) (<= longitude max-longitude)) err-invalid-input)
        (ok (map-set bus-locations bus-id 
            (merge bus {
                latitude: latitude,
                longitude: longitude
            })))))

(define-read-only (get-bus-info (bus-id uint))
    (map-get? bus-locations bus-id))

;; Route management functions
(define-public (add-route (route-id uint) (name (string-ascii 50)) (stops (list 20 uint)))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? routes route-id)) err-already-exists)
        (asserts! (<= (len stops) max-route-stops) err-invalid-input)
        (asserts! (> (len stops) u0) err-invalid-input)
        (asserts! (> (len name) u0) err-invalid-input)
        (ok (map-set routes route-id {name: (if (> (len name) u0) name "Unnamed Route"), stops: stops}))))

(define-read-only (get-route (route-id uint))
    (map-get? routes route-id))

;; Fare management functions
(define-public (update-base-fare (new-fare uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (> new-fare u0) err-invalid-input)
        (var-set base-fare new-fare)
        (ok true)))

(define-read-only (get-base-fare)
    (ok (var-get base-fare)))

;; Dynamic pricing functions
(define-public (set-time-multiplier (hour uint) (multiplier uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (and (< hour u24) (>= multiplier min-multiplier) (<= multiplier max-multiplier)) err-invalid-input)
        (map-set time-multipliers hour multiplier)
        (ok true)))

(define-public (set-demand-multiplier (demand-level uint) (multiplier uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (and (< demand-level u5) (>= multiplier min-multiplier) (<= multiplier max-multiplier)) err-invalid-input)
        (map-set demand-multipliers demand-level multiplier)
        (ok true)))

(define-public (set-special-event-multiplier (event-id uint) (multiplier uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= event-id u1000) err-invalid-input)  ;; Add a reasonable upper limit for event IDs
        (asserts! (and (>= multiplier min-multiplier) (<= multiplier max-multiplier)) err-invalid-input)
        (map-set special-event-multipliers event-id multiplier)
        (ok true)))

(define-read-only (calculate-fare (base-price uint) (hour uint) (demand-level uint) (special-event-id (optional uint)))
    (let
        ((time-mult (default-to u100 (map-get? time-multipliers hour)))
         (demand-mult (default-to u100 (map-get? demand-multipliers demand-level)))
         (event-mult (match special-event-id
                          event-id (default-to u100 (map-get? special-event-multipliers event-id))
                          u100))
         (total-mult (/ (* (* time-mult demand-mult) event-mult) (* u100 u100))))
        (ok (/ (* base-price total-mult) u100))))

;; Operator management functions
(define-public (register-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-none (map-get? bus-operators operator)) err-already-exists)
        (asserts! (not (is-eq operator tx-sender)) err-invalid-input)
        (map-set bus-operators operator true)
        (ok true)))

(define-public (revoke-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (is-some (map-get? bus-operators operator)) err-not-found)
        (ok (map-delete bus-operators operator))))

;; Loyalty program functions
(define-public (add-loyalty-points (user principal) (points uint))
    (begin
        (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (as-contract tx-sender))) err-unauthorized)
        (asserts! (and (> points u0) (<= points u1000000)) err-invalid-input)  ;; Add a reasonable upper limit for points
        (let ((current-points (default-to u0 (map-get? loyalty-points user))))
            (asserts! (<= (+ current-points points) u1000000000) err-invalid-input)  ;; Prevent overflow
            (ok (map-set loyalty-points user (+ current-points points))))))
(define-public (redeem-loyalty-points (points uint))
    (let ((user-points (default-to u0 (map-get? loyalty-points tx-sender))))
        (asserts! (>= user-points points) err-insufficient-balance)
        (asserts! (> points u0) err-invalid-input)
        (map-set loyalty-points tx-sender (- user-points points))
        (try! (as-contract (stx-transfer? (* points u1) tx-sender tx-sender)))
        (ok true)))

(define-read-only (get-loyalty-points (user principal))
    (ok (default-to u0 (map-get? loyalty-points user))))

;; Carbon credits function
(define-public (add-carbon-credits (amount uint))
    (begin
        (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (as-contract tx-sender))) err-unauthorized)
        (asserts! (> amount u0) err-invalid-input)
        (ok (var-set carbon-credits (+ (var-get carbon-credits) amount)))))

(define-read-only (get-carbon-credits)
    (ok (var-get carbon-credits)))

;; DAO voting functions
(define-public (create-proposal (description (string-ascii 500)) (deadline uint))
    (let
        ((new-id (+ (var-get proposal-id-nonce) u1)))
        (asserts! (> (default-to u0 (map-get? balances tx-sender)) u0) err-unauthorized)
        (asserts! (> deadline block-height) err-invalid-input)
        (asserts! (> (len description) u0) err-invalid-input)
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
        (asserts! (> amount u0) err-invalid-input)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (ok (map-set balances tx-sender (+ (default-to u0 (map-get? balances tx-sender)) amount)))))

(define-public (withdraw (amount uint))
    (let ((current-balance (default-to u0 (map-get? balances tx-sender))))
        (asserts! (>= current-balance amount) err-insufficient-balance)
        (map-set balances tx-sender (- current-balance amount))
        (try! (stx-transfer? amount (as-contract tx-sender) tx-sender))
        (ok true)))
