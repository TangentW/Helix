#if canImport(UIKit)
import HelixBytecode
import HelixCore
@testable import HelixDevRuntime
import HelixLiveReloadAPI
import HelixRuntime
import HelixVerifier
import HelixVM
import Testing
import UIKit

enum DevRuntimeIOSTests {}

extension DevRuntimeIOSTests {
@MainActor
class IdentityController: UIViewController {}

@MainActor
final class IdentityChildController: IdentityController {}

@MainActor
final class IdentityView: UIView {}

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

    @Test("Runtime type names reproduce compiler nominal identities")
    func derivesRuntimeTypeIdentities() {
        let resolver = UIKitReload.TypeIdentityResolver()
        let nested = resolver.nominalTypeID(
            reflectedName: "FeatureModule.FeatureNamespace.ScreenController"
        )
        #expect(nested == LiveReload.NominalTypeID.derive(
            module: "FeatureModule",
            canonicalName: "FeatureNamespace.ScreenController"
        ))
        #expect(resolver.nominalTypeID(reflectedName: "UnqualifiedType") == nil)
        #expect(resolver.nominalTypeID(reflectedName: "Module.") == nil)

        let baseID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadUIKitTests",
            canonicalName: "DevRuntimeIOSTests.IdentityController"
        )
        let childID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadUIKitTests",
            canonicalName: "DevRuntimeIOSTests.IdentityChildController"
        )
        let childIDs = resolver.nominalTypeIDs(
            for: DevRuntimeIOSTests.IdentityChildController.self
        )
        #expect(childIDs.contains(childID))
        #expect(childIDs.contains(baseID))
    }

    @Test("Displayed subclass and view instances match actions without registration")
    func resolvesActionsWithoutRegistry() throws {
        let baseID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadUIKitTests",
            canonicalName: "DevRuntimeIOSTests.IdentityController"
        )
        let childID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadUIKitTests",
            canonicalName: "DevRuntimeIOSTests.IdentityChildController"
        )
        let viewID = LiveReload.NominalTypeID.derive(
            module: "LiveReloadUIKitTests",
            canonicalName: "DevRuntimeIOSTests.IdentityView"
        )
        let resolver = UIKitReload.InstanceActionResolver()
        let controllerResult = resolver.resolve(
            [
                .init(
                    nominalTypeID: baseID,
                    policy: .invalidate,
                    invalidationHints: [.layout]
                ),
                .init(
                    nominalTypeID: childID,
                    policy: .invalidate,
                    invalidationHints: [.display]
                ),
            ],
            in: [DevRuntimeIOSTests.IdentityChildController()]
        )
        #expect(controllerResult.matches.count == 1)
        #expect(controllerResult.matches.first?.action.invalidationHints == [.layout, .display])
        #expect(controllerResult.matchedNominalTypeIDs == [baseID, childID])
        #expect(controllerResult.errors.isEmpty)

        let viewResult = resolver.resolve(
            [
                .init(
                    nominalTypeID: viewID,
                    policy: .invalidate,
                    invalidationHints: [.display]
                ),
            ],
            in: [DevRuntimeIOSTests.IdentityView()]
        )
        #expect(viewResult.matches.count == 1)
        #expect(viewResult.matchedNominalTypeIDs == [viewID])
        #expect(viewResult.errors.isEmpty)
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

    @Test("Debug overlay keeps a readable width and expands failures")
    func debugOverlaySizingAndFailurePresentation() throws {
        let configuration = DebugOverlay.Configuration(
            startsExpanded: false,
            automaticallyHides: false
        )
        let panel = DebugOverlay.PanelView(
            snapshot: .init(
                phase: .authenticated,
                tone: .success,
                headline: "Connected"
            ),
            configuration: configuration,
            manualReloadHandler: {}
        )
        let collapsed = panel.preferredOverlaySize(maximumWidth: 390)
        #expect(collapsed.width > 80)
        #expect(collapsed.width <= 390)
        #expect(collapsed.height < 60)

        panel.update(
            .init(
                sequence: 1,
                phase: .failed,
                tone: .error,
                headline: "Compile failed · old code active",
                detail: "Correct the unsupported source and save again."
            )
        )
        let expanded = panel.preferredOverlaySize(maximumWidth: 390)
        #expect(panel.isPresented)
        #expect(panel.isExpanded)
        #expect(expanded.width >= 340)
        #expect(expanded.width <= 390)

        let pill = try #require(
            panel.subviews.compactMap { $0 as? UIButton }.first
        )
        #expect(pill.configuration?.title?.contains("Compile failed") == true)
        #expect(pill.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } == true)
    }

    @Test("Debug overlay placement remains inside the safe area")
    func debugOverlayPlacementIsClamped() {
        let configuration = DebugOverlay.Configuration()
        #expect(configuration.automaticallyHides)
        let size = CGSize(width: 340, height: 180)
        let safeArea = CGSize(width: 390, height: 844)
        let initial = DebugOverlay.Placement.defaultAnchor(
            size: size,
            safeAreaSize: safeArea,
            configuration: configuration
        )
        #expect(initial == CGPoint(x: 378, y: 12))
        #expect(
            DebugOverlay.Placement.origin(anchor: initial, size: size)
                == CGPoint(x: 38, y: 12)
        )

        let upperLeft = DebugOverlay.Placement.clampedAnchor(
            CGPoint(x: -1_000, y: -1_000),
            size: size,
            safeAreaSize: safeArea,
            configuration: configuration
        )
        let lowerRight = DebugOverlay.Placement.clampedAnchor(
            CGPoint(x: 1_000, y: 1_000),
            size: size,
            safeAreaSize: safeArea,
            configuration: configuration
        )
        #expect(upperLeft == CGPoint(x: 352, y: 12))
        #expect(lowerRight == CGPoint(x: 378, y: 652))
    }

    @Test("Debug overlay auto-hides and a later event presents it again")
    func debugOverlayAutoHideLifecycle() {
        var scheduledAction: (@MainActor () -> Void)?
        var cancellationCount = 0
        let scheduler: DebugOverlay.PanelView.AutoHideScheduler = { action in
            scheduledAction = action
            return { cancellationCount += 1 }
        }
        let panel = DebugOverlay.PanelView(
            snapshot: .init(),
            configuration: .init(automaticallyHides: true),
            autoHideScheduler: scheduler,
            manualReloadHandler: {}
        )
        #expect(scheduledAction != nil)
        scheduledAction?()
        #expect(!panel.isPresented)

        panel.update(
            .init(
                sequence: 1,
                phase: .compiling,
                tone: .progress,
                headline: "Compiling 1"
            )
        )
        #expect(panel.isPresented)
        #expect(!panel.isHidden)
        #expect(cancellationCount == 1)
        panel.prepareForRemoval()

        var persistentScheduleCount = 0
        let persistent = DebugOverlay.PanelView(
            snapshot: .init(),
            configuration: .init(automaticallyHides: false),
            autoHideScheduler: { _ in
                persistentScheduleCount += 1
                return {}
            },
            manualReloadHandler: {}
        )
        #expect(persistent.isPresented)
        #expect(persistentScheduleCount == 0)
        persistent.prepareForRemoval()
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

    @Test("A hosted UIViewController executes its pinned HLBC lifecycle callback")
    func hostedUIViewControllerExecutesLifecycle() throws {
        let namespace = Core.ShellNamespaceID.derive(
            bundleID: "dev.helix.ios-hosted",
            buildNumber: "1",
            seed: "fixture"
        )
        let typeID = Core.TypeID.derive(
            namespace: namespace,
            canonicalType: "UIKit.UIViewController"
        )
        let typeKey = Bytecode.LocalTypeKey(rawValue: "Fixture.EmergencyController")
        let entry = Core.EntryIndex(rawValue: 0)
        let functionKey = try Core.FunctionKey.derive(
            namespace: namespace,
            module: "HostedUIKitFixture",
            sourceFileLogicalID: "Patch.swift",
            canonicalDeclaration: "func makeController() -> UIViewController",
            loweredSignature: .init(parameters: [], result: "UIKit.UIViewController"),
            role: .function
        )
        let compatibility = Core.Compatibility(
            runtime: Core.Versions.runtime,
            bytecode: Core.Versions.bytecode,
            interfaceArchive: Core.Versions.interfaceArchive,
            compilerFingerprint: "hosted-uikit-fixture"
        )
        let shellHash = Core.Digest.sha256("hosted-uikit-shell")
        let layout = Core.Digest.sha256("UIViewController-layout")
        let method = Bytecode.HostedMethod(
            selector: "viewDidLoad",
            functionID: .init(rawValue: 1),
            abi: .voidNoArguments
        )
        let capabilities: Set<Core.Capability> = [
            .baselineV1,
            .nativeTypesV1,
            .localNominalsV1,
            .localClassesV1,
            .borrowCallsV1,
            .hostedObjectiveCClassesV1,
            .mainActorSyncV1,
        ]
        let module = Bytecode.Module(
            name: "HostedUIKitFixture",
            shellInterfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            localTypes: [
                .init(
                    key: typeKey,
                    kind: .class(
                        fields: [],
                        hostedSuperclass: .init(typeID: typeID),
                        hostedMethods: [method]
                    )
                ),
            ],
            functions: [
                .init(
                    id: .init(rawValue: 0),
                    name: "makeController",
                    parameterRegisters: [],
                    resultType: .native(typeID),
                    registerTypes: [.local(typeKey), .native(typeID)],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            instructions: [
                                .allocateObject(result: .init(rawValue: 0)),
                                .projectHostedObject(
                                    result: .init(rawValue: 1),
                                    object: .init(rawValue: 0)
                                ),
                                .returnValue(.init(rawValue: 1)),
                            ]
                        ),
                    ],
                    effects: .init(mayAllocate: true, requiresMainActor: true)
                ),
                .init(
                    id: method.functionID,
                    name: "EmergencyController.viewDidLoad",
                    parameterRegisters: [.init(rawValue: 0)],
                    parameterConventions: [.borrowed],
                    resultType: .void,
                    registerTypes: [.local(typeKey)],
                    entryBlock: .init(rawValue: 0),
                    blocks: [
                        .init(
                            id: .init(rawValue: 0),
                            parameters: [.init(rawValue: 0)],
                            instructions: [
                                .hostedSuperApply(
                                    object: .init(rawValue: 0),
                                    methodIndex: 0,
                                    arguments: []
                                ),
                                .trap(.explicit("lifecycle marker")),
                            ]
                        ),
                    ],
                    effects: .init(
                        hasExternalSideEffects: true,
                        requiresMainActor: true
                    )
                ),
            ],
            entries: [
                .init(
                    entryIndex: entry,
                    functionKey: functionKey,
                    functionID: .init(rawValue: 0)
                ),
            ]
        )
        let shell = try Verification.ShellInterface(
            interfaceHash: shellHash,
            compatibility: compatibility,
            capabilities: capabilities,
            entries: [
                .init(
                    index: entry,
                    key: functionKey,
                    parameterTypes: [],
                    resultType: .native(typeID),
                    effects: .init(mayAllocate: true, requiresMainActor: true)
                ),
            ],
            types: [
                .init(
                    id: typeID,
                    canonicalName: "UIKit.UIViewController",
                    kind: .reference,
                    layoutFingerprint: layout,
                    isCopyable: true,
                    requiresMainActor: true,
                    estimatedSize: 8
                ),
            ]
        )
        let typeCatalog = try VM.NativeTypeCatalog([
            .reference(
                id: typeID,
                canonicalName: "UIKit.UIViewController",
                layoutFingerprint: layout,
                requiresMainActor: true,
                describe: { (value: UIViewController) in String(describing: value) }
            ),
        ])
        let bytes = try Bytecode.Encoder.encode(module)
        let image = try Verification.Engine().verify(
            bytes: bytes,
            shell: shell,
            policy: .init(
                acceptedCapabilities: capabilities,
                allowMainActorSynchronousEntries: true
            )
        )
        let fallback = try typeCatalog.box(UIViewController(), as: typeID)
        let observer = HostedObserver()
        let engine = Runtime.Engine(
            originals: try .init([
                .init(index: entry, parameterTypes: [], resultType: .native(typeID)) { _ in
                    .returned(.native(fallback))
                },
            ]),
            shellInterfaceHash: shellHash,
            nativeTypeCatalog: typeCatalog,
            observer: observer
        )
        try engine.activate(
            .init(
                id: .init(rawValue: 1),
                parentID: nil,
                packageID: "HLX-hosted-uikit",
                packageHash: .sha256(bytes),
                images: [image],
                estimatedByteCount: bytes.count
            ),
            expectedActiveID: nil
        )

        guard case let .returned(.native(value)?) = engine.invoke(
            entry: entry,
            arguments: []
        ), let controller = value.value(as: UIViewController.self) else {
            Issue.record("hosted UIKit allocation failed")
            return
        }
        #expect(object_getClass(controller) !== UIViewController.self)

        controller.loadViewIfNeeded()

        #expect(controller.isViewLoaded)
        #expect(observer.diagnostics.map(\.selector) == ["viewDidLoad"])
    }

    @Test("Subview resolution covers controller and direct window trees once")
    func resolvesNestedViews() {
        let controller = FixtureController()
        controller.loadViewIfNeeded()
        let outer = FixtureView()
        let inner = FixtureView()
        let directWindowView = FixtureView()
        let window = UIWindow()
        outer.addSubview(inner)
        controller.view.addSubview(outer)
        window.addSubview(directWindowView)

        let resolved = UIKitReload.InstanceResolver().views(
            in: [controller, controller],
            windows: [window, window]
        )
        let fixtures = resolved.compactMap { $0 as? FixtureView }
        #expect(fixtures.count == 3)
        #expect(fixtures.contains { $0 === directWindowView })
        #expect(Set(resolved.map(ObjectIdentifier.init)).count == resolved.count)
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
        #expect(environment.reload.latestReport?.warnings.isEmpty == true)
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

    private final class HostedObserver: Runtime.Observing, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Runtime.HostedTrapDiagnostic] = []

        var diagnostics: [Runtime.HostedTrapDiagnostic] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func didActivate(generation: Runtime.GenerationID) {}
        func didRollback(from: Runtime.GenerationID, to: Runtime.GenerationID?) {}
        func didTrap(
            generation: Runtime.GenerationID,
            entry: Core.EntryIndex,
            trap: VM.RuntimeTrap
        ) {}

        func didTrap(hostedDiagnostic: Runtime.HostedTrapDiagnostic) {
            lock.lock()
            storage.append(hostedDiagnostic)
            lock.unlock()
        }
    }
}
}
#endif
