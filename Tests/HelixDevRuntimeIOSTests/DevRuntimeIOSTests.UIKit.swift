#if canImport(UIKit)
import HelixBytecode
import HelixCore
@testable import HelixDevRuntime
import HelixLiveReloadAPI
import HelixVM
import Testing
import UIKit

enum DevRuntimeIOSTests {}

extension DevRuntimeIOSTests {
@MainActor
@Suite("UIKit Live Reload integration")
struct UIKitIntegration {
    private final class FixtureController: UIViewController {}
    private final class FixtureView: UIView {}
    private final class CountingTableView: UITableView {
        private(set) var reloadCount = 0

        override func reloadData() {
            reloadCount += 1
            super.reloadData()
        }
    }

    private enum IsHiddenGetterFactory: VM.NativeImportFactory {
        static let viewTypeID = Core.TypeID(rawValue: .sha256("UIKit.UIView.fixture"))

        static func make(
            id: Core.NativeImportID,
            key: Core.NativeImportKey
        ) -> any VM.NativeInvoker {
            VM.ClosureNativeInvoker(
                id: id,
                key: key,
                parameterTypes: [.native(viewTypeID)],
                resultType: .bool,
                effects: .init(requiresMainActor: true),
                contract: .bounded(
                    kind: .instanceGetter,
                    domain: .uiKit,
                    access: .read,
                    maximumDurationMicroseconds: 500,
                    allowsMainThread: true
                )
            ) { arguments, context in
                guard case let .native(box)? = arguments.first,
                      let view = box.value(as: UIView.self)
                else { return .businessError("expected UIView") }
                return try context.withMainActor {
                    .returned(.bool(view.isHidden))
                }
            }
        }
    }

    @Test("A nominal identity maps to exactly one UIKit target kind")
    func registryTargetKindIsExclusive() {
        let id = LiveReload.NominalTypeID.derive(
            module: "Fixture",
            canonicalName: "FixtureController"
        )
        let registry = UIKitReload.TypeRegistry()
        registry.register(FixtureController.self, for: id)
        #expect(registry.controllerType(for: id) == FixtureController.self)
        #expect(registry.viewType(for: id) == nil)

        registry.register(FixtureView.self, for: id)
        #expect(registry.controllerType(for: id) == nil)
        #expect(registry.viewType(for: id) == FixtureView.self)
    }

    @Test("Transparent overlay space does not consume application touches")
    func debugOverlayRootPassesThroughEmptySpace() {
        let root = DebugOverlay.PassThroughView(
            frame: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        let button = UIButton(frame: CGRect(x: 40, y: 40, width: 80, height: 40))
        root.addSubview(button)

        #expect(root.hitTest(CGPoint(x: 10, y: 10), with: nil) == nil)
        #expect(root.hitTest(CGPoint(x: 60, y: 60), with: nil) === button)
    }

    @Test("A typed UIKit NativeImport compiles through the verified MainActor context")
    func nativeImportMainActorEntryCompiles() throws {
        let invoker = IsHiddenGetterFactory.make(
            id: .init(rawValue: 0),
            key: .init(rawValue: .sha256("UIKit.UIView.isHidden.getter"))
        )
        #expect(invoker.contract.domain == .uiKit)
        #expect(invoker.effects.requiresMainActor)
    }

    @Test("Subview resolution finds nested registered views once")
    func resolvesNestedViews() {
        let controller = FixtureController()
        controller.loadViewIfNeeded()
        let outer = FixtureView()
        let inner = FixtureView()
        outer.addSubview(inner)
        controller.view.addSubview(outer)

        let resolved = UIKitReload.InstanceResolver().views(
            matching: FixtureView.self,
            in: [controller, controller]
        )
        #expect(resolved.count == 2)
        #expect(Set(resolved.map(ObjectIdentifier.init)).count == 2)
    }

    @Test("Data invalidation is not reported as applied when broad reload is disabled")
    func dataInvalidationIsTruthful() {
        let root = UIView()
        let table = CountingTableView(frame: .zero, style: .plain)
        root.addSubview(table)

        let disabled = UIKitReload.Invalidator(
            broadDataReloadEnabled: false
        ).invalidate(
            root,
            hints: [.tableData],
            allowsImmediateLayout: true
        )
        #expect(!disabled.didApply)
        #expect(table.reloadCount == 0)
        #expect(disabled.warnings.count == 1)

        let enabled = UIKitReload.Invalidator(
            broadDataReloadEnabled: true
        ).invalidate(
            root,
            hints: [.tableData],
            allowsImmediateLayout: true
        )
        #expect(enabled.didApply)
        #expect(table.reloadCount == 1)
        #expect(enabled.warnings.isEmpty)
    }

    @Test("Safe layout work can succeed while skipped broad work remains a warning")
    func partialInvalidationRemainsApplied() {
        let result = UIKitReload.Invalidator(
            broadDataReloadEnabled: false
        ).invalidate(
            UIView(),
            hints: [.layout, .collectionData],
            allowsImmediateLayout: true
        )
        #expect(result.didApply)
        #expect(result.warnings.count == 1)

        let blockedLayout = UIKitReload.Invalidator().invalidate(
            UIView(),
            hints: [.immediateLayout],
            allowsImmediateLayout: false
        )
        #expect(!blockedLayout.didApply)
        #expect(blockedLayout.warnings.count == 1)
    }

    @Test("Unified environment routes a generation to its active SwiftUI boundary")
    func unifiedEnvironmentRoutesSwiftUI() async {
        let id = LiveReload.NominalTypeID.derive(
            module: "Fixture",
            canonicalName: "ProfileScreen"
        )
        let pulse = LiveReload.Pulse()
        let token = pulse.registerBoundary(for: id)
        defer { pulse.unregisterBoundary(token) }
        let environment = DevRuntime.LiveReloadEnvironment(pulse: pulse)
        let context = LiveReload.Context(
            generationID: 1,
            sourceRevision: 1,
            changedFunctions: [],
            reason: .manual
        )
        let status = await environment.activationReloadHandler()(
            context,
            [
                .init(
                    nominalTypeID: id,
                    policy: .invalidate,
                    invalidationHints: [.layout]
                ),
            ]
        )
        #expect(status == .refreshed)
        #expect(environment.reload.latestReport?.refreshedTargetCount == 1)
        #expect(pulse.refreshSequence(for: id) == 1)

        environment.status.handle(
            .activationCompleted(
                .init(
                    sourceRevision: .init(rawValue: 1),
                    generationID: .init(rawValue: 1),
                    codeStatus: .codeActive,
                    reloadStatus: status
                )
            )
        )
        #expect(environment.status.snapshot.headline.contains("UI refreshed"))
        let manual = await environment.reload.manualReloadLatest()
        #expect(manual.status == .refreshed)
        #expect(pulse.refreshSequence(for: id) == 2)
    }

    @Test("An invalid activation context does not replace the latest reloadable generation")
    func invalidContextIsNotRemembered() async {
        let reload = UIReload.Coordinator()
        let report = await reload.reload(
            context: .init(
                generationID: 0,
                changedFunctions: [],
                reason: .manual
            ),
            hints: []
        )
        #expect(report.status == .failed)
        #expect(reload.latestContext == nil)
    }
}
}
#endif
