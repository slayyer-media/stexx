import Foundation
import Observation
import StoreKit
import SwiftUI

/// Stexx+ through StoreKit 2.
///
/// StoreKit only proves a purchase happened; the entitlement itself comes
/// from the server. After every purchase, restore or `Transaction.updates`
/// delivery the transaction's JWS is sent to `POST /subscriptions/apple`, and
/// `AppState.hasPlus` is then set from `GET /subscriptions/status`.
/// Transactions are finished only once the server accepted them, so StoreKit
/// redelivers anything that didn't make it (offline, signed out, …).
@MainActor
@Observable
final class PurchaseService {
    nonisolated static let productIDs: Set<String> = [PlusProduct.monthlyID]

    private(set) var product: Product?
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    var errorMessage: String?

    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(api: any APIClient, appState: AppState) {
        self.api = api
        self.appState = appState
    }

    /// Localized price ("$9.99"), or a placeholder until products load.
    var displayPrice: String {
        product?.displayPrice ?? PlusProduct.placeholderPrice
    }

    // MARK: Lifecycle

    /// Starts listening for transactions (renewals, purchases made on other
    /// devices, Ask to Buy approvals, refunds). Call once at launch.
    func listenForTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.process(result)
            }
        }
    }

    /// After sign-in: load the product, hand any unfinished transactions to
    /// the server and fetch the entitlement.
    func signedIn() async {
        await loadProducts()
        for await result in Transaction.unfinished {
            await process(result, refresh: false)
        }
        await refreshEntitlement()
    }

    func loadProducts() async {
        guard product == nil else { return }
        do {
            product = try await Product.products(for: Self.productIDs).first
        } catch {
            // The paywall falls back to the placeholder price.
        }
    }

    /// Server-side entitlement → `AppState.hasPlus`.
    func refreshEntitlement() async {
        guard appState.session != nil else { return }
        do {
            appState.applySubscription(try await api.subscriptionStatus())
        } catch {
            // Keep the current state on network errors; 402/401 are handled
            // by the client hooks.
        }
    }

    // MARK: Purchase & restore

    func purchase(using purchaseAction: PurchaseAction) async {
        await loadProducts()
        guard let product else {
            errorMessage = String(localized: "Stexx+ isn't available right now. Try again later.")
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        errorMessage = nil
        do {
            switch try await purchaseAction(product) {
            case .success(let verification):
                await process(verification)
                if !appState.hasPlus {
                    errorMessage = String(localized: "We couldn't confirm your purchase yet. It will activate automatically.")
                }
            case .pending:
                errorMessage = String(localized: "Your purchase is pending approval.")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Syncs with the App Store and re-submits current entitlements.
    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        errorMessage = nil
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        var found = false
        for await result in Transaction.currentEntitlements {
            guard Self.productIDs.contains(result.unsafePayloadValue.productID) else { continue }
            found = true
            await process(result, refresh: false)
        }
        await refreshEntitlement()
        if !found && !appState.hasPlus {
            errorMessage = String(localized: "No Stexx+ subscription found for this Apple Account.")
        }
    }

    #if DEBUG
    /// Grants Plus via the mock or the dev server (`POST /v1/dev/plus`).
    func debugGrantPlus() async {
        do {
            try await api.debugGrantPlus()
            await refreshEntitlement()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    // MARK: Server verification

    /// Sends a transaction to the server and finishes it once accepted.
    /// Unverified transactions are sent too: the server is the judge.
    private func process(_ result: VerificationResult<StoreKit.Transaction>, refresh: Bool = true) async {
        let transaction = result.unsafePayloadValue
        guard Self.productIDs.contains(transaction.productID) else {
            await transaction.finish()
            return
        }
        // Without a session there's nobody to credit; StoreKit will deliver
        // it again via `Transaction.unfinished` after sign-in.
        guard appState.session != nil else { return }
        do {
            let status = try await api.submitAppleTransaction(signedTransaction: result.jwsRepresentation)
            appState.applySubscription(status)
            await transaction.finish()
        } catch {
            // Left unfinished on purpose so it's retried later.
        }
        if refresh { await refreshEntitlement() }
    }
}
