import XCTest
@testable import ShoppingWatch

@MainActor
final class WatchShoppingSessionTests: XCTestCase {
    func testOptimisticAddMovesImmediatelyAndCoalescesRepeatTap() async throws {
        let service = SpyService(), started = expectation(description: "Save held")
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let before = session.snapshot
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let command = WatchShoppingCommand.add(token: "bananas", quantity: 6)
        let task = Task { await session.perform(command) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(session.snapshot.grocerySections.flatMap(\.items).contains { $0.id == "bananas" })
        let row = try XCTUnwrap(session.snapshot.item(id: "bananas"))
        XCTAssertTrue(row.isInOwnCart)
        XCTAssertTrue(row.isPendingAdd)
        XCTAssertEqual(row.quantity, 6)
        XCTAssertTrue(row.canRemove && row.canChangeQuantity)
        XCTAssertFalse(row.canBuyAnyway)
        XCTAssertFalse(session.snapshot.canCheckout)
        XCTAssertEqual(session.snapshot.cartCount, before.cartCount + 1)
        XCTAssertEqual(session.snapshot.cartSections.map(\.id), ["Produce", "Dairy"])
        let repeated = await session.perform(command)
        XCTAssertFalse(repeated)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(service.commands, [command])
        service.value = savedBananas(before, quantity: 6)
        service.commandContinuation?.resume(returning: service.value)
        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertEqual(session.snapshot, service.value)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.id, "saved-membership")
        XCTAssertFalse(session.snapshot.item(id: "bananas")?.isPendingAdd ?? true)
    }

    func testOlderHeldRefreshCannotUndoOptimisticAddOrDuplicateExistingMembership() async throws {
        let service = SpyService()
        let model = WatchShoppingSession(service: service)
        await model.reload()
        let old = service.value
        let loadStarted = expectation(description: "Old load held")
        service.suspendNextLoad = true
        service.loadStarted = { loadStarted.fulfill() }
        let refresh = Task { await model.reload() }
        await fulfillment(of: [loadStarted], timeout: 2)
        let reserved = expectation(description: "Add reserved")
        let commandStarted = expectation(description: "Command started after read")
        service.suspendCommand = true
        service.commandStarted = { commandStarted.fulfill() }
        let task = Task { reserved.fulfill(); return await model.perform(.add(token: "bananas", quantity: 9)) }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertEqual(model.snapshot.item(id: "bananas")?.quantity, 9)
        XCTAssertTrue(service.commands.isEmpty)
        // Another replica has already carted the same need with a different
        // membership ID and quantity. A repeated Add preserves that claim.
        let existing = savedBananas(old, quantity: 4)
        service.loadContinuation?.resume(returning: existing)
        await refresh.value
        await fulfillment(of: [commandStarted], timeout: 2)
        XCTAssertEqual(model.snapshot.cartCount, 2)
        XCTAssertEqual(model.snapshot.item(id: "bananas")?.quantity, 4)
        XCTAssertTrue(model.snapshot.item(id: "bananas")?.isPendingAdd ?? false)
        service.value = existing
        let coalesced = expectation(description: "Coalesced import read")
        service.onLoad = { if service.loadCount == 3 { coalesced.fulfill() } }
        for _ in 0..<20 { service.onChange?(.dataChanged) }
        service.commandContinuation?.resume(returning: existing)
        let succeeded = await task.value
        XCTAssertTrue(succeeded)
        await fulfillment(of: [coalesced], timeout: 2)
        XCTAssertEqual(model.snapshot, existing)
        XCTAssertEqual(service.loadCount, 3)
        // A later authoritative removal is not hidden by a lingering overlay.
        service.value = old
        await model.reload()
        XCTAssertFalse(model.snapshot.item(id: "bananas")?.isInOwnCart ?? true)
    }

    func testFailedOptimisticAddUsesLatestSnapshotAndCanRetryNilQuantity() async throws {
        let service = SpyService(), started = expectation(description: "Save held")
        let session = WatchShoppingSession(service: service)
        await session.reload()
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let task = Task { await session.perform(.add(token: "bananas", quantity: nil)) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(session.snapshot.item(id: "bananas")?.quantity)
        service.value.grocerySections[0].items[0].notes = "Latest imported note"
        service.commandContinuation?.resume(throwing: NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Save failed"]))
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertEqual(session.snapshot, service.value)
        XCTAssertEqual(session.errorMessage, "Save failed")
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.canAdd ?? false)
        service.suspendCommand = false
        service.value = savedBananas(service.value, quantity: nil)
        let retry = await session.perform(.add(token: "bananas", quantity: nil))
        XCTAssertTrue(retry)
        XCTAssertNil(session.snapshot.item(id: "bananas")?.quantity)
        XCTAssertNil(session.errorMessage)
    }

    func testCommittedAddReadFailureReconcilesWithoutReexecuting() async {
        let service = SpyService()
        let model = WatchShoppingSession(service: service)
        await model.reload()
        let saved = savedBananas(service.value, quantity: 7)
        service.shouldFail = true
        service.onCommand = { service.value = saved }
        let success = await model.perform(.add(token: "bananas", quantity: 7))
        XCTAssertTrue(success)
        XCTAssertEqual(model.snapshot, saved)
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testCommittedAddReceiptFailureReportsCanceledFollowingQuantityAndRemoval() async throws {
        let followingCommands: [WatchShoppingCommand] = [
            .setQuantity(token: "bananas", quantity: 5),
            .remove(token: "bananas")
        ]
        for following in followingCommands {
            let service = SpyService()
            let session = WatchShoppingSession(service: service)
            await session.reload()
            let started = expectation(description: "Predecessor Add held for \(following)")
            service.suspendCommand = true
            service.commandStarted = { started.fulfill() }
            let adding = Task { await session.perform(.add(token: "bananas", quantity: 1)) }
            await fulfillment(of: [started], timeout: 2)
            let reserved = expectation(description: "Following edit accepted")
            let editing = Task { reserved.fulfill(); return await session.perform(following) }
            await fulfillment(of: [reserved], timeout: 2)
            if case .setQuantity = following {
                XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 5, "The later quantity was accepted before the receipt failed")
            } else {
                XCTAssertNil(session.snapshot.item(id: "bananas"), "The later removal was accepted before the receipt failed")
            }
            service.value = savedBananas(service.value, quantity: 1)
            service.commandContinuation?.resume(throwing: NSError(domain: "Receipt read failed", code: 1))
            let predecessorSaved = await adding.value
            let followingSaved = await editing.value
            XCTAssertTrue(predecessorSaved, "The authoritative reread confirms the original Add")
            XCTAssertFalse(followingSaved, "A lost receipt cannot authorize replay through a replacement token")
            XCTAssertEqual(service.commands, [.add(token: "bananas", quantity: 1)])
            XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 1)
            XCTAssertTrue(session.snapshot.item(id: "bananas")?.isInOwnCart ?? false)
            XCTAssertFalse(session.hasUnconfirmedAdd)
            XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.")
            await session.reload()
            XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.",
                "A later ordinary read must not erase unapplied-edit feedback")
        }
    }

    func testCanceledFollowingEditFeedbackSurvivesDelayedRecoveryAndClearsWithAuthority() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Original Add held")
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let adding = Task { await session.perform(.add(token: "bananas", quantity: 1)) }
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Quantity five accepted")
        let editing = Task { reserved.fulfill(); return await session.perform(.setQuantity(token: "bananas", quantity: 5)) }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 5)
        service.value = savedBananas(service.value, quantity: 1)
        service.failLoad = true
        service.commandContinuation?.resume(throwing: NSError(domain: "Receipt read failed", code: 1))
        let predecessorConfirmed = await adding.value
        let followingSaved = await editing.value
        XCTAssertFalse(predecessorConfirmed)
        XCTAssertFalse(followingSaved)
        XCTAssertTrue(session.hasUnconfirmedAdd)
        XCTAssertTrue(session.errorMessage?.contains("Later changes to this item were not applied") ?? false)
        session.errorMessage = nil // The alert binding resets when Check cart is selected.
        service.failLoad = false
        await session.reload()
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 1)
        XCTAssertEqual(service.commands, [.add(token: "bananas", quantity: 1)])
        XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.")
        service.value = WatchShoppingSnapshot(authorityID: "new-account", availability: .ready)
        service.onChange?(.authorityInvalidated)
        XCTAssertNil(session.errorMessage, "Canceled edits from the old account cannot produce feedback in the new account")
        XCTAssertFalse(session.hasUnconfirmedAdd)
    }

    func testExplicitErrorAcknowledgementPreventsCanceledNoticeReturningOnRecovery() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Original Add held")
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let adding = Task { await session.perform(.add(token: "bananas", quantity: 1)) }
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Following removal accepted")
        let removing = Task { reserved.fulfill(); return await session.perform(.remove(token: "bananas")) }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertNil(session.snapshot.item(id: "bananas"))
        service.value = savedBananas(service.value, quantity: 1)
        service.failLoad = true
        service.commandContinuation?.resume(throwing: NSError(domain: "Receipt read failed", code: 1))
        _ = await adding.value
        _ = await removing.value
        XCTAssertTrue(session.hasUnconfirmedAdd)
        XCTAssertTrue(session.errorMessage?.contains("Later changes to this item were not applied") ?? false)
        session.acknowledgeError()
        XCTAssertNil(session.errorMessage)
        service.failLoad = false
        await session.reload()
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 1)
        XCTAssertEqual(service.commands, [.add(token: "bananas", quantity: 1)])
        XCTAssertNil(session.errorMessage, "Explicit OK acknowledges the cancellation notice as well as dismissing the alert")
    }

    func testUnsafeReceiptCancellationFeedbackSurvivesUnrelatedFailureReconciliation() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Original Add held")
        var held: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { command in
            if case .add = command {
                return try await withCheckedThrowingContinuation { held = $0; started.fulfill() }
            }
            throw NSError(domain: "Independent removal failed", code: 1)
        }
        let adding = Task { await session.perform(.add(token: "bananas", quantity: 1)) }
        await fulfillment(of: [started], timeout: 2)
        let quantityReserved = expectation(description: "Dependent quantity accepted")
        let editing = Task { quantityReserved.fulfill(); return await session.perform(.setQuantity(token: "bananas", quantity: 5)) }
        await fulfillment(of: [quantityReserved], timeout: 2)
        let removalReserved = expectation(description: "Independent removal accepted")
        let removing = Task { removalReserved.fulfill(); return await session.perform(.remove(token: "milk")) }
        await fulfillment(of: [removalReserved], timeout: 2)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 5)
        XCTAssertNil(session.snapshot.item(id: "milk"))
        service.value = savedBananas(service.value, quantity: 4)
        held?.resume(returning: .item(occurrenceID: "bananas",
            item: localItem("bananas", token: "remote-replacement", quantity: 4), mayRebase: false))
        let predecessorSaved = await adding.value
        let dependentSaved = await editing.value
        let independentSaved = await removing.value
        XCTAssertTrue(predecessorSaved)
        XCTAssertFalse(dependentSaved)
        XCTAssertFalse(independentSaved)
        XCTAssertEqual(service.commands, [.add(token: "bananas", quantity: 1), .remove(token: "milk")],
            "The unrelated intent still executes, without replaying the unsafe dependent quantity")
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 4)
        XCTAssertTrue(session.snapshot.item(id: "milk")?.isInOwnCart ?? false)
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.")
        await session.reload()
        XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.")
        service.onLoad = { service.value.selectedStoreID = WatchPreviewService.secondStoreID }
        await session.reload()
        XCTAssertEqual(session.snapshot.selectedStoreID, WatchPreviewService.secondStoreID,
            "The returned snapshot must actually change store scope despite the previously requested selection")
        XCTAssertNil(session.errorMessage, "An automatic store-selection change must clear feedback from the old scope")
    }

    func testUnconfirmedAddBlocksOnlyThatOccurrenceUntilReconnectReadResolvesIt() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let saved = savedBananas(service.value, quantity: 1)
        service.shouldFail = true
        service.failLoad = true
        service.onCommand = { service.value = saved }
        let command = WatchShoppingCommand.add(token: "bananas", quantity: 1)
        let success = await session.perform(command)
        XCTAssertFalse(success)
        XCTAssertTrue(session.hasUnconfirmedAdd)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.isAddUnconfirmed ?? false)
        XCTAssertTrue(session.errorMessage?.contains("may already be saved") ?? false)
        let repeated = await session.perform(command)
        XCTAssertFalse(repeated)
        service.shouldFail = false
        let other = await session.perform(.remove(token: "milk"))
        XCTAssertTrue(other)
        XCTAssertEqual(service.commands.count, 2)
        service.failLoad = false
        await session.reload()
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertEqual(session.snapshot, saved)
        XCTAssertNil(session.errorMessage)
    }

    func testOfflineSavedAddSurvivesStatusChangesAndReconnect() async {
        let service = SpyService(), started = expectation(description: "Local save held")
        service.value.syncStatus = WatchSyncStatus(attentionMessages: ["Offline; waiting to sync"])
        let session = WatchShoppingSession(service: service)
        await session.reload()
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let task = Task { await session.perform(.add(token: "bananas", quantity: 99)) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.isPendingAdd ?? false)
        let saved = savedBananas(service.value, quantity: 99)
        service.value = saved
        service.commandContinuation?.resume(returning: saved)
        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertEqual(session.snapshot.syncStatus.state, .attention)
        service.onChange?(.syncChanged(WatchSyncStatus()))
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 99)
        service.value.syncStatus = WatchSyncStatus()
        await session.reload()
        XCTAssertEqual(session.snapshot.cartCount, 2)
        XCTAssertEqual(service.commands.count, 1)
    }

    func testAuthorityInvalidationDuringFailureReconciliationCannotResurrectPendingAdd() async {
        let service = SpyService(), started = expectation(description: "Reconciliation held")
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let oldSaved = savedBananas(service.value, quantity: 3)
        service.shouldFail = true
        service.suspendNextLoad = true
        service.loadStarted = { started.fulfill() }
        let task = Task { await session.perform(.add(token: "bananas", quantity: 3)) }
        await fulfillment(of: [started], timeout: 2)
        let newAccountLoaded = expectation(description: "Replacement account loaded")
        service.onLoad = { if service.loadCount == 3 { newAccountLoaded.fulfill() } }
        service.value = WatchShoppingSnapshot(authorityID: "new-account", availability: .ready)
        service.onChange?(.authorityInvalidated)
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        service.loadContinuation?.resume(returning: oldSaved)
        let success = await task.value
        XCTAssertFalse(success)
        await fulfillment(of: [newAccountLoaded], timeout: 2)
        XCTAssertEqual(session.snapshot.authorityID, "new-account")
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertNil(session.errorMessage)
    }

    func testUnconfirmedFailureRecoversToUncartedStateWithoutRetryingWrite() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        service.shouldFail = true
        service.failLoad = true
        let success = await session.perform(.add(token: "bananas", quantity: nil))
        XCTAssertFalse(success)
        XCTAssertTrue(session.hasUnconfirmedAdd)
        service.failLoad = false
        await session.reload()
        XCTAssertEqual(session.snapshot, service.value)
        XCTAssertFalse(session.hasUnconfirmedAdd)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.canAdd ?? false)
        XCTAssertEqual(service.commands.count, 1)
    }

    func testHeldRefreshKeepsPendingAddVisibleThenFailureUsesRefreshedMetadata() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let read = expectation(description: "Read held")
        service.suspendNextLoad = true
        service.loadStarted = { read.fulfill() }
        let refresh = Task { await session.reload() }
        await fulfillment(of: [read], timeout: 2)
        let started = expectation(description: "Command held")
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let reserved = expectation(description: "Add reserved")
        let adding = Task { reserved.fulfill(); return await session.perform(.add(token: "bananas", quantity: 2)) }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.isPendingAdd ?? false)
        service.value.grocerySections[0].items[0].notes = "New note from earlier read"
        service.loadContinuation?.resume(returning: service.value)
        await refresh.value
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.isPendingAdd ?? false)
        XCTAssertEqual(session.snapshot.cartCount, 2)
        service.commandContinuation?.resume(throwing: NSError(domain: "test", code: 2))
        _ = await adding.value
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.notes, "New note from earlier read")
        XCTAssertFalse(session.snapshot.item(id: "bananas")?.isInOwnCart ?? true)
    }

    func testPendingAddPreservesSettingsCategoryRankAndOccurrenceNameOrdering() async {
        let service = SpyService()
        service.value.cartSections = [
            WatchItemSection(id: "active", title: "First",
                items: [localItem("bread", token: "bread", quantity: 1)], categoryOrder: -1),
            WatchItemSection(id: "Produce", title: "Produce", items: [
                localItem("zucchini", token: "zucchini", quantity: 1),
                localItem("apples", token: "apples", quantity: 2)
            ]),
            WatchItemSection(id: "archived", title: "Archived",
                items: [localItem("soap", token: "soap", quantity: 1)], categoryRank: 1),
            WatchItemSection(id: "uncategorized", title: "Uncategorized",
                items: [localItem("coffee", token: "coffee", quantity: 1)], categoryRank: 2)
        ]
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Command held")
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let adding = Task { await session.perform(.add(token: "bananas", quantity: 3)) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(session.snapshot.cartSections.map(\.id), ["active", "Produce", "archived", "uncategorized"])
        XCTAssertEqual(session.snapshot.cartSections.first { $0.id == "Produce" }?.items.map(\.name),
            ["Apples", "Bananas", "Zucchini"])
        XCTAssertTrue(session.snapshot.cartSections.allSatisfy { !$0.items.isEmpty })
        service.commandContinuation?.resume(returning: service.value)
        _ = await adding.value
    }

    func testDifferentItemBurstQuantityAndRemovalProjectWhileFirstLocalWriteIsHeld() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "First local write held")
        let remaining = expectation(description: "Remaining local intents committed")
        remaining.expectedFulfillmentCount = 3
        var first: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { command in
            switch command {
            case .add(let token, _) where token == "bananas":
                return try await withCheckedThrowingContinuation { first = $0; started.fulfill() }
            case .add(let token, let quantity):
                XCTAssertEqual(token, "granola")
                remaining.fulfill()
                return .item(occurrenceID: "granola", item: self.localItem("granola", token: "granola-saved", quantity: quantity))
            case .setQuantity(let token, let quantity):
                XCTAssertEqual(token, "granola-saved", "Only its own local Add receipt supplies this causal token")
                remaining.fulfill()
                return .item(occurrenceID: "granola", item: self.localItem("granola", token: "granola-edited", quantity: quantity))
            case .remove(let token):
                XCTAssertEqual(token, "bananas-saved")
                remaining.fulfill()
                return .item(occurrenceID: "bananas", item: nil)
            default: throw NSError(domain: "Unexpected command", code: 1)
            }
        }
        XCTAssertTrue(session.submit(.add(token: "bananas", quantity: 3)))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.submit(.add(token: "granola", quantity: 1)))
        XCTAssertTrue(session.submit(.setQuantity(token: "granola", quantity: 5)))
        XCTAssertTrue(session.submit(.remove(token: "bananas")))
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.snapshot.canCheckout)
        XCTAssertEqual(session.snapshot.item(id: "granola")?.quantity, 5)
        XCTAssertNil(session.snapshot.item(id: "bananas"))
        XCTAssertFalse(session.snapshot.cartSections.contains { $0.id == "Produce" }, "Removing the only pending row also removes its heading")
        XCTAssertTrue(session.snapshot.cartSections.allSatisfy { !$0.items.isEmpty })
        XCTAssertEqual(session.snapshot.cartCount, 2)
        XCTAssertEqual(service.commands.count, 1)
        first?.resume(returning: .item(occurrenceID: "bananas", item: localItem("bananas", token: "bananas-saved", quantity: 3)))
        await fulfillment(of: [remaining], timeout: 2)
        await Task.yield()
        XCTAssertEqual(service.commands.count, 4)
        XCTAssertEqual(session.snapshot.item(id: "granola")?.quantity, 5)
        XCTAssertFalse(session.snapshot.item(id: "granola")?.isPendingAdd ?? true)
        XCTAssertNil(session.snapshot.item(id: "bananas"))
        XCTAssertTrue(session.snapshot.cartSections.allSatisfy { !$0.items.isEmpty })
    }

    func testRapidQuantityReversalRetainsLatestDesiredValueWhileEarlierSameValueIsPending() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "First quantity write held")
        let remaining = expectation(description: "Both later quantity intents committed")
        remaining.expectedFulfillmentCount = 2
        var held: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { command in
            guard case .setQuantity(let token, let quantity) = command else {
                throw NSError(domain: "Unexpected command", code: 1)
            }
            switch service.commands.count {
            case 1:
                XCTAssertEqual(quantity, 2)
                return try await withCheckedThrowingContinuation { held = $0; started.fulfill() }
            case 2:
                XCTAssertEqual(token, "milk-first")
                XCTAssertEqual(quantity, 3)
                remaining.fulfill()
                return .item(occurrenceID: "milk", item: self.localItem("milk", token: "milk-second", quantity: 3))
            default:
                XCTAssertEqual(token, "milk-second")
                XCTAssertEqual(quantity, 2)
                remaining.fulfill()
                return .item(occurrenceID: "milk", item: self.localItem("milk", token: "milk-final", quantity: 2))
            }
        }
        XCTAssertTrue(session.submit(.setQuantity(token: "milk", quantity: 2)))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.submit(.setQuantity(token: "milk", quantity: 3)))
        XCTAssertTrue(session.submit(.setQuantity(token: "milk", quantity: 2)), "Returning to an earlier queued value is a new intent")
        XCTAssertFalse(session.submit(.setQuantity(token: "milk", quantity: 2)), "Only a repeat of the latest desired value coalesces")
        XCTAssertEqual(session.snapshot.item(id: "milk")?.quantity, 2)
        XCTAssertEqual(service.commands.count, 1)
        held?.resume(returning: .item(occurrenceID: "milk", item: localItem("milk", token: "milk-first", quantity: 2)))
        await fulfillment(of: [remaining], timeout: 2)
        await Task.yield()
        XCTAssertEqual(service.commands.count, 3)
        XCTAssertEqual(session.snapshot.item(id: "milk")?.quantity, 2)
        XCTAssertFalse(session.snapshot.item(id: "milk")?.isPendingAdd ?? true)
        XCTAssertEqual(session.snapshot.item(id: "milk")?.commandToken, "milk-final")
    }

    func testOlderLocalAcknowledgementCannotEraseNewerQueuedQuantity() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let adding = expectation(description: "Add held")
        let editing = expectation(description: "Quantity held")
        var add: CheckedContinuation<WatchShoppingCommit, Error>?
        var edit: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { command in
            switch command {
            case .add:
                return try await withCheckedThrowingContinuation { add = $0; adding.fulfill() }
            case .setQuantity(let token, let quantity):
                XCTAssertEqual(token, "local-add")
                XCTAssertEqual(quantity, 8)
                return try await withCheckedThrowingContinuation { edit = $0; editing.fulfill() }
            default: throw NSError(domain: "Unexpected command", code: 1)
            }
        }
        XCTAssertTrue(session.submit(.add(token: "bananas", quantity: 3)))
        await fulfillment(of: [adding], timeout: 2)
        let reserved = expectation(description: "Newer quantity reserved")
        let update = Task { reserved.fulfill(); return await session.perform(.setQuantity(token: "bananas", quantity: 8)) }
        await fulfillment(of: [reserved], timeout: 2)
        add?.resume(returning: .item(occurrenceID: "bananas", item: localItem("bananas", token: "local-add", quantity: 3)))
        await fulfillment(of: [editing], timeout: 2)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 8)
        XCTAssertTrue(session.snapshot.item(id: "bananas")?.isPendingAdd ?? false)
        edit?.resume(returning: .item(occurrenceID: "bananas", item: localItem("bananas", token: "local-edit", quantity: 8)))
        let saved = await update.value
        XCTAssertTrue(saved)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 8)
        XCTAssertFalse(session.snapshot.item(id: "bananas")?.isPendingAdd ?? true)
    }

    func testRemoteReplacementReceiptNeverRetargetsQueuedQuantity() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Add held before imported replacement is observed")
        var held: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { _ in
            try await withCheckedThrowingContinuation { held = $0; started.fulfill() }
        }
        XCTAssertTrue(session.submit(.add(token: "bananas", quantity: 3)))
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Quantity reserved before receipt")
        let queued = Task { reserved.fulfill(); return await session.perform(.setQuantity(token: "bananas", quantity: 9)) }
        await fulfillment(of: [reserved], timeout: 2)
        held?.resume(returning: .item(occurrenceID: "bananas",
            item: localItem("bananas", token: "remote-replacement", quantity: 4), mayRebase: false))
        let applied = await queued.value
        XCTAssertFalse(applied)
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 4)
        XCTAssertFalse(session.snapshot.item(id: "bananas")?.isPendingAdd ?? true)
        XCTAssertEqual(session.errorMessage, "Later changes to this item were not applied. Check your cart before trying again.")
    }

    func testIncomingChangeCoalescesBehindDirtyLocalIntentsAndCatchesUp() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "First local write held")
        let imported = expectation(description: "Incoming state read after local commits")
        var held: CheckedContinuation<WatchShoppingCommit, Error>?
        service.onLoad = { if service.loadCount == 2 { imported.fulfill() } }
        service.commitHandler = { command in
            if case .add(let token, _) = command, token == "bananas" {
                return try await withCheckedThrowingContinuation { held = $0; started.fulfill() }
            }
            let granola = self.localItem("granola", token: "local-granola", quantity: 6)
            service.value = self.savedBananas(service.value, quantity: 3)
            service.value.grocerySections[1].items.removeAll { $0.id == "granola" }
            service.value.cartSections.append(WatchItemSection(id: "Pantry", title: "Pantry", items: [granola]))
            service.value.statusMessage = "Incoming phone change"
            return .item(occurrenceID: "granola", item: granola)
        }
        XCTAssertTrue(session.submit(.add(token: "bananas", quantity: 3)))
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.submit(.add(token: "granola", quantity: 6)))
        for _ in 0..<20 { service.onChange?(.dataChanged) }
        XCTAssertEqual(session.snapshot.item(id: "granola")?.quantity, 6)
        XCTAssertTrue(session.snapshot.item(id: "granola")?.isInOwnCart ?? false)
        XCTAssertEqual(service.loadCount, 1, "A stale read cannot overtake local dirty intents")
        held?.resume(returning: .item(occurrenceID: "bananas", item: localItem("bananas", token: "local-bananas", quantity: 3)))
        await fulfillment(of: [imported], timeout: 2)
        await Task.yield()
        XCTAssertEqual(session.snapshot.statusMessage, "Incoming phone change")
        XCTAssertEqual(session.snapshot.item(id: "granola")?.quantity, 6)
        XCTAssertEqual(session.snapshot.cartCount, 3)
        XCTAssertEqual(service.commands.count, 2)
        XCTAssertEqual(service.loadCount, 2)
    }

    func testBoundedIncomingReadDuringQueuedEditsPreservesDesiredQuantityAndCapturedToken() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service, incomingRefreshInterval: .zero)
        await session.reload()
        let started = expectation(description: "Add held")
        let editing = expectation(description: "Quantity dispatched after incoming read")
        var add: CheckedContinuation<WatchShoppingCommit, Error>?
        var edit: CheckedContinuation<WatchShoppingCommit, Error>?
        service.commitHandler = { command in
            switch command {
            case .add:
                return try await withCheckedThrowingContinuation { add = $0; started.fulfill() }
            case .setQuantity(let token, _):
                XCTAssertEqual(service.loadCount, 2, "Incoming local-store read must not wait for the entire backlog")
                XCTAssertEqual(token, "own-add", "An imported replacement cannot retarget the captured local intent")
                return try await withCheckedThrowingContinuation { edit = $0; editing.fulfill() }
            default: throw NSError(domain: "Unexpected command", code: 1)
            }
        }
        XCTAssertTrue(session.submit(.add(token: "bananas", quantity: 3)))
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Quantity intent reserved")
        let change = Task { reserved.fulfill(); return await session.perform(.setQuantity(token: "bananas", quantity: 8)) }
        await fulfillment(of: [reserved], timeout: 2)
        service.value = savedBananas(service.value, quantity: 4)
        service.value.cartSections[0].items[0].commandToken = "remote-replacement"
        service.onChange?(.dataChanged)
        add?.resume(returning: .item(occurrenceID: "bananas", item: localItem("bananas", token: "own-add", quantity: 3)))
        await fulfillment(of: [editing], timeout: 2)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 8)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.commandToken, "own-add")
        edit?.resume(throwing: NSError(domain: "Stale captured membership", code: 1))
        let applied = await change.value
        XCTAssertFalse(applied)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.quantity, 4)
        XCTAssertEqual(session.snapshot.item(id: "bananas")?.commandToken, "remote-replacement")
        XCTAssertEqual(service.commands.count, 2)
    }

    func testFailedAddRetainsExplicitQuantityDraftForReopenedCard() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        service.shouldFail = true
        let applied = await session.perform(.add(token: "granola", quantity: 2))
        XCTAssertFalse(applied)
        let row = try XCTUnwrap(session.snapshot.item(id: "granola"))
        XCTAssertFalse(row.isInOwnCart)
        XCTAssertNil(row.quantity)
        XCTAssertEqual(session.quantityDraft(for: row), 2)
    }

    private func localItem(_ occurrence: String, token: String, quantity: Int?) -> WatchShoppingItem {
        WatchShoppingItem(id: "membership-" + occurrence, commandToken: token, name: occurrence.capitalized,
            quantity: quantity, rule: .canBuyHere, isInOwnCart: true, needID: occurrence,
            canRemove: true, canChangeQuantity: true)
    }

    private func savedBananas(_ source: WatchShoppingSnapshot, quantity: Int?) -> WatchShoppingSnapshot {
        var value = source
        value.grocerySections[0].items.removeAll { $0.id == "bananas" }
        value.cartSections.insert(WatchItemSection(id: "Produce", title: "Produce", items: [
            WatchShoppingItem(id: "saved-membership", commandToken: "saved-token", name: "Bananas",
                quantity: quantity, rule: .canBuyHere, isInOwnCart: true, needID: "bananas",
                canRemove: true, canChangeQuantity: true)
        ]), at: 0)
        value.canCheckout = true
        return value
    }

    func testNormalLaunchRequiresSetupWithoutFixtures() async {
        let session = WatchShoppingSession(service: UnavailableWatchShoppingService())
        await session.reload()
        guard case .setupRequired = session.snapshot.availability else {
            return XCTFail("A production launch must not expose fixture groceries")
        }
        XCTAssertTrue(session.snapshot.stores.isEmpty)
        XCTAssertFalse(session.snapshot.canCheckout)
    }

    func testSyncActivityUpdatesIconWithoutReloadingGroceries() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let groceries = session.snapshot.grocerySections
        XCTAssertEqual(service.loadCount, 1)
        var cloud = CloudSyncStatus()
        cloud.record(.init(store: "private", operation: .upload, started: Date(),
            ended: nil, failure: nil))
        service.onChange?(.syncChanged(WatchSyncStatus(cloud: cloud)))
        XCTAssertEqual(session.snapshot.syncStatus.state, .working)
        XCTAssertEqual(session.snapshot.grocerySections, groceries)
        XCTAssertEqual(service.loadCount, 1)
    }

    func testImportedDataRequestsAWatchSnapshotWithoutChangingAuthority() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let originalAuthority = session.snapshot.authorityID
        let imported = expectation(description: "Imported data loaded")
        service.onLoad = { if service.loadCount == 2 { imported.fulfill() } }
        service.value.statusMessage = "Imported grocery change"

        service.onChange?(.dataChanged)

        await fulfillment(of: [imported], timeout: 2)
        await Task.yield()
        XCTAssertEqual(service.loadCount, 2)
        XCTAssertEqual(session.snapshot.statusMessage, "Imported grocery change")
        XCTAssertEqual(session.snapshot.authorityID, originalAuthority)
    }

    func testExplicitNativeRefreshDoesNotOccupySessionOrRunOnLocalReloads() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        XCTAssertEqual(service.accessRefreshCount, 0)
        session.refreshHomeAccess()
        XCTAssertEqual(service.accessRefreshCount, 1)
        XCTAssertFalse(session.isBusy)
        await session.reload(storeID: UUID())
        XCTAssertEqual(service.accessRefreshCount, 1, "A local reload or store switch must not launch another network request")
        let removed = await session.perform(.remove(token: "saved-private-entry"))
        XCTAssertTrue(removed, "Dispatching refresh must not occupy the session's command state")
    }

    func testActiveRefreshWaitsBeforeFirstReadAndStopsWhenCancelled() async {
        let coordinator = WatchActiveRefreshCoordinator(interval: .milliseconds(50))
        let refreshed = expectation(description: "Active fallback read")
        var readCount = 0
        let task = Task {
            await coordinator.run {
                readCount += 1
                refreshed.fulfill()
            }
        }
        XCTAssertEqual(readCount, 0)
        await fulfillment(of: [refreshed], timeout: 2)
        let countAtCancellation = readCount
        task.cancel()
        await task.value
        XCTAssertEqual(readCount, countAtCancellation)
    }

    func testAddDuringHeldRefreshIsRetainedOnceAndImportsCoalesce() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Background read held")
        service.suspendNextLoad = true
        service.loadStarted = { started.fulfill() }
        let refresh = Task { await session.reload() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(session.isBusy, "Ordinary reads must not disable Add")
        let command = WatchShoppingCommand.add(token: "captured-occurrence", quantity: 3)
        let reserved = expectation(description: "Add reserved")
        let adding = Task { reserved.fulfill(); return await session.perform(command) }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertFalse(session.isBusy, "A queued local edit must not disable independent rows")
        XCTAssertTrue(service.commands.isEmpty, "Service operations must remain serialized")
        let coalesced = expectation(description: "One coalesced follow-up read")
        service.onLoad = { if service.loadCount == 3 { coalesced.fulfill() } }
        for _ in 0..<20 { service.onChange?(.dataChanged) }
        // The periodic coordinator uses this same local reload entry point.
        await session.reload()
        await Task.yield()
        service.loadContinuation?.resume(returning: service.value)
        await refresh.value
        let applied = await adding.value
        XCTAssertTrue(applied)
        XCTAssertEqual(service.commands, [command])
        await fulfillment(of: [coalesced], timeout: 2)
        XCTAssertEqual(service.loadCount, 3, "Initial read, held read, one coalesced follow-up")
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.errorMessage)
    }

    func testQueuedAddCannotRunUnderReplacementAuthority() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let old = service.value
        let started = expectation(description: "Old-account read held")
        service.suspendNextLoad = true
        service.loadStarted = { started.fulfill() }
        let refresh = Task { await session.reload() }
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Old-account Add reserved")
        let adding = Task { reserved.fulfill(); return await session.perform(.add(token: "old-account", quantity: 2)) }
        await fulfillment(of: [reserved], timeout: 2)
        let replacementLoaded = expectation(description: "Replacement authority read")
        service.onLoad = { if service.loadCount == 3 { replacementLoaded.fulfill() } }
        service.value.authorityID = "replacement-account"
        service.onChange?(.authorityInvalidated)
        await Task.yield()
        service.loadContinuation?.resume(returning: old)
        await refresh.value
        let applied = await adding.value
        XCTAssertFalse(applied)
        XCTAssertTrue(service.commands.isEmpty)
        await fulfillment(of: [replacementLoaded], timeout: 2)
        XCTAssertEqual(session.snapshot.authorityID, "replacement-account")
        XCTAssertNil(session.errorMessage)
    }

    func testQueuedAddRejectsChangedHomeAndKeepsActionableFeedback() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Prior home read held")
        service.suspendNextLoad = true
        service.loadStarted = { started.fulfill() }
        let refresh = Task { await session.reload() }
        await fulfillment(of: [started], timeout: 2)
        let reserved = expectation(description: "Old-home Add reserved")
        let adding = Task { reserved.fulfill(); return await session.perform(.add(token: "old-home", quantity: nil)) }
        await fulfillment(of: [reserved], timeout: 2)
        service.value.authorityID = "another-home"
        service.loadContinuation?.resume(returning: service.value)
        await refresh.value
        let applied = await adding.value
        XCTAssertFalse(applied)
        XCTAssertTrue(service.commands.isEmpty)
        XCTAssertEqual(session.errorMessage, PersonalCartError.scopeChanged.localizedDescription)
        await session.reload()
        XCTAssertNotNil(session.errorMessage)
    }

    func testPeriodicRefreshCoalescesWhileLoadHeldAndPreservesStoreChoice() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let started = expectation(description: "Local refresh held")
        service.suspendNextLoad = true
        service.loadStarted = { started.fulfill() }
        let refresh = Task { await session.reload() }
        await fulfillment(of: [started], timeout: 2)
        let timerFired = expectation(description: "Periodic refresh requested")
        var didFire = false
        let periodic = Task {
            await WatchActiveRefreshCoordinator(interval: .milliseconds(1)).run {
                await session.reload()
                if !didFire { didFire = true; timerFired.fulfill() }
            }
        }
        await fulfillment(of: [timerFired], timeout: 2)
        periodic.cancel()
        await periodic.value
        XCTAssertFalse(session.isBusy)
        let reserved = expectation(description: "Store selection reserved")
        var selectionFinished = false
        let selection = Task {
            reserved.fulfill()
            await session.reload(storeID: WatchPreviewService.secondStoreID)
            selectionFinished = true
        }
        await fulfillment(of: [reserved], timeout: 2)
        XCTAssertFalse(selectionFinished, "The store chooser must await the actual selected snapshot")
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(service.loadCount, 2)
        service.loadContinuation?.resume(returning: service.value)
        await refresh.value
        await selection.value
        XCTAssertEqual(service.loadCount, 4)
        XCTAssertEqual(session.snapshot.selectedStoreID, WatchPreviewService.secondStoreID)
        XCTAssertEqual(service.requestedStores.last, WatchPreviewService.secondStoreID)
        XCTAssertFalse(session.isBusy)
    }

    func testRefreshCannotEraseFailedCommandFeedback() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        service.shouldFail = true
        let applied = await session.perform(.add(token: "stale-token", quantity: 2))
        XCTAssertFalse(applied)
        XCTAssertEqual(session.errorMessage, "Save failed")
        await session.reload()
        XCTAssertEqual(session.errorMessage, "Save failed", "A periodic read must not dismiss the error alert")
    }

    func testFailedSaveRetainsSnapshotAndOpaqueCommand() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let before = session.snapshot
        service.shouldFail = true
        let command = WatchShoppingCommand.remove(token: "account-bound:membership-generation:revision")
        let succeeded = await session.perform(command)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(service.commands, [command])
        XCTAssertEqual(session.snapshot, before)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(session.isBusy)
    }

    func testCommandReportsSuccessOnlyForReadySameAuthoritySnapshot() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let command = WatchShoppingCommand.add(token: "pending-occurrence", quantity: 2)
        let succeeded = await session.perform(command)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(service.commands, [command])
        service.value.authorityID = "different-account"
        let changedAuthority = await session.perform(command)
        XCTAssertFalse(changedAuthority)
        service.value.availability = .setupRequired("Household unavailable")
        let unavailable = await session.perform(command)
        XCTAssertFalse(unavailable)
    }

    func testQueuedIndependentCommandAndInvalidatedResultDoNotChangeNewAuthority() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        let previous = session.snapshot
        let started = expectation(description: "Add suspended")
        service.suspendCommand = true
        service.commandStarted = { started.fulfill() }
        let first = WatchShoppingCommand.add(token: "old-authority", quantity: 2)
        let pending = Task { await session.perform(first) }
        await fulfillment(of: [started], timeout: 2)
        let accepted = session.submit(.add(token: "second", quantity: 3))
        XCTAssertTrue(accepted)
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(service.commands, [first], "Local writes remain serialized without rejecting independent taps")
        let replacementLoaded = expectation(description: "New authority after old commit discarded")
        service.onLoad = { if service.loadCount == 2 { replacementLoaded.fulfill() } }
        service.value.authorityID = "new-account"
        service.onChange?(.authorityInvalidated)
        await Task.yield()
        service.commandContinuation?.resume(returning: previous)
        let staleResult = await pending.value
        XCTAssertFalse(staleResult)
        await fulfillment(of: [replacementLoaded], timeout: 2)
        XCTAssertEqual(session.snapshot.authorityID, "new-account")
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isBusy)
    }

    func testCheckoutRetryKeepsCapturedRowsAndSameToken() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        let preview = try XCTUnwrap(session.checkoutPreview)
        service.value.cartSections = [] // A later snapshot must not redefine the captured operation.
        await session.reload()
        XCTAssertEqual(session.checkoutPreview, preview)
        service.shouldFail = true
        await session.confirmCheckout(preview)
        XCTAssertEqual(session.checkoutPreview, preview)
        XCTAssertEqual(service.checkoutTokens, [preview.token])
        service.shouldFail = false
        await session.confirmCheckout(preview)
        XCTAssertEqual(service.checkoutTokens, [preview.token, preview.token])
        XCTAssertNil(session.checkoutPreview)
        XCTAssertNotNil(session.result)
        XCTAssertNil(session.errorMessage)
    }

    func testOfflineSnapshotAllowsOwnerRemovalAndRestoreUsesExactToken() async {
        let service = SpyService()
        service.value.statusMessage = "Saved on watch"
        service.value.canCheckout = false
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.perform(.remove(token: "orphaned-own-membership"))
        XCTAssertEqual(service.commands, [.remove(token: "orphaned-own-membership")])
        let operation = WatchRecoveryOperation(id: UUID(), token: "owner-scoped-receipt", storeName: "Costco", summary: "2 items", canRestore: true)
        await session.restore(operation)
        XCTAssertEqual(service.restoreTokens, [operation.token])
    }

    func testEmptyCaptureRefreshesInsteadOfShowingFalseConfirmation() async {
        let service = SpyService()
        service.captureRows = []
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        XCTAssertNil(session.checkoutPreview)
        XCTAssertEqual(session.errorMessage, "Your cart changed. There are no eligible items to check out.")
        XCTAssertTrue(service.checkoutTokens.isEmpty)
    }

    func testUnavailableAndChangedAuthorityClearOldCheckout() async {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        service.value.availability = .setupRequired("Sign in again")
        await session.reload()
        XCTAssertNil(session.checkoutPreview)
        XCTAssertNil(session.result)

        service.value = WatchPreviewService.sample
        service.value.canCheckout = true
        await session.reload()
        await session.prepareCheckout()
        XCTAssertNotNil(session.checkoutPreview)
        service.value.authorityID = "different-account"
        await session.reload()
        XCTAssertNil(session.checkoutPreview)
    }

    func testAuthorityInvalidationDiscardsSuspendedCheckoutResult() async throws {
        let service = SpyService()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        let preview = try XCTUnwrap(session.checkoutPreview)
        let previousSnapshot = session.snapshot
        let started = expectation(description: "Checkout suspended")
        service.suspendCheckout = true
        service.checkoutStarted = { started.fulfill() }
        let pending = Task { await session.confirmCheckout(preview) }
        await fulfillment(of: [started], timeout: 2)

        service.value.authorityID = "new-account"
        service.value.cartSections = []
        service.onChange?(.authorityInvalidated)
        XCTAssertNil(session.sheet)
        XCTAssertEqual(session.snapshot.availability, .loading)
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        await Task.yield()
        service.checkoutContinuation?.resume(returning: WatchActionResult(id: UUID(), title: "Old account result", message: "Must not reappear", skippedNames: [], snapshot: previousSnapshot))
        await pending.value
        XCTAssertEqual(session.snapshot.authorityID, "new-account")
        XCTAssertTrue(session.snapshot.cartSections.isEmpty)
        XCTAssertNil(session.result)
        XCTAssertNil(session.errorMessage)
    }

    func testInvalidSelectionCannotCaptureAndPadlocksHaveDistinctMeaning() async {
        let service = SpyService()
        service.value.selectedStoreID = UUID()
        let session = WatchShoppingSession(service: service)
        await session.reload()
        await session.prepareCheckout()
        XCTAssertEqual(service.captureCount, 0)
        XCTAssertNil(session.checkoutPreview)
        XCTAssertEqual(WatchPurchaseRule.onlyHere.symbol, "lock.fill")
        XCTAssertEqual(WatchPurchaseRule.canBuyHere.symbol, "lock.open.fill")
    }
}

@MainActor
private final class SpyService: WatchShoppingService {
    var onChange: (@MainActor (WatchServiceChange) -> Void)?
    var value = WatchPreviewService.sample
    var loadCount = 0
    var requestedStores: [UUID?] = []
    var accessRefreshCount = 0
    var onLoad: (() -> Void)?
    var suspendNextLoad = false
    var loadStarted: (() -> Void)?
    var loadContinuation: CheckedContinuation<WatchShoppingSnapshot, Never>?
    var shouldFail = false
    var failLoad = false
    var onCommand: (() -> Void)?
    var commitHandler: ((WatchShoppingCommand) async throws -> WatchShoppingCommit)?
    var commands: [WatchShoppingCommand] = []
    var checkoutTokens: [String] = []
    var restoreTokens: [String] = []
    var suspendCommand = false
    var commandStarted: (() -> Void)?
    var commandContinuation: CheckedContinuation<WatchShoppingSnapshot, Error>?
    var suspendCheckout = false
    var checkoutStarted: (() -> Void)?
    var checkoutContinuation: CheckedContinuation<WatchActionResult, Never>?
    var captureCount = 0
    var captureRows = WatchPreviewService.previewCheckout.rows

    init() { value.canCheckout = true }
    func refreshHomeAccess() { accessRefreshCount += 1 }
    func load(storeID: UUID?) async throws -> WatchShoppingSnapshot {
        loadCount += 1
        if failLoad { throw failure }
        requestedStores.append(storeID)
        if let storeID { value.selectedStoreID = storeID }
        onLoad?()
        if suspendNextLoad {
            suspendNextLoad = false
            return await withCheckedContinuation { continuation in
                loadContinuation = continuation
                loadStarted?()
            }
        }
        return value
    }
    func commit(_ command: WatchShoppingCommand) async throws -> WatchShoppingCommit {
        if let commitHandler {
            commands.append(command)
            return try await commitHandler(command)
        }
        return .snapshot(try await execute(command))
    }
    func execute(_ command: WatchShoppingCommand) async throws -> WatchShoppingSnapshot {
        commands.append(command)
        onCommand?()
        if suspendCommand {
            return try await withCheckedThrowingContinuation { continuation in
                commandContinuation = continuation
                commandStarted?()
            }
        }
        if shouldFail { throw failure }
        return value
    }
    func captureCheckout(storeID: UUID) async throws -> WatchCheckoutPreview {
        captureCount += 1
        return WatchCheckoutPreview(id: UUID(), token: "captured-scope", storeName: "Costco", rows: captureRows)
    }
    func checkout(token: String) async throws -> WatchActionResult {
        checkoutTokens.append(token)
        if suspendCheckout {
            return await withCheckedContinuation { continuation in
                checkoutContinuation = continuation
                checkoutStarted?()
            }
        }
        if shouldFail { throw failure }
        return WatchActionResult(id: UUID(), title: "1 cleared", message: "1 changed item skipped", skippedNames: ["Oat milk"], snapshot: value)
    }
    func restore(token: String) async throws -> WatchActionResult {
        restoreTokens.append(token)
        return WatchActionResult(id: UUID(), title: "Restored", message: "Saved on watch", skippedNames: [], snapshot: value)
    }
    private var failure: NSError { NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed"]) }
}
