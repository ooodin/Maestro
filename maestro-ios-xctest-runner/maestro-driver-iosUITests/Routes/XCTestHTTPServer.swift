import FlyingFox
import Foundation

enum Route: String, CaseIterable {
    case runningApp
    case swipe
    case swipeV2
    case inputText
    case touch
    case screenshot
    case isScreenStatic
    case pressKey
    case pressButton
    case eraseText
    case deviceInfo
    case setOrientation
    case setAppearance
    case appearance
    case setPermissions
    case viewHierarchy
    case status
    case keyboard
    case launchApp
    case terminateApp

    func toHTTPRoute() -> HTTPRoute {
        return HTTPRoute(rawValue)
    }
}

struct XCTestHTTPServer {
    func start() async throws {
        let port = ProcessInfo.processInfo.environment["PORT"]?.toUInt16()
        let server = HTTPServer(address: try .inet(ip4: "127.0.0.1", port: port ?? 22087), timeout: 100)
        
        for route in Route.allCases {
            let handler = await RouteHandlerFactory.createRouteHandler(route: route)
            await server.appendRoute(route.toHTTPRoute(), to: handler)
        }
        
        // Pomerado routes: strict, POST JSON under /pomerado/.
        await server.appendRoute("POST /pomerado/status", to: PomeradoStatusHandler())
        await server.appendRoute("POST /pomerado/hierarchy", to: await MainActor.run { PomeradoHierarchyHandler() })
        await server.appendRoute("POST /pomerado/touch", to: await MainActor.run { PomeradoTouchHandler() })
        await server.appendRoute("POST /pomerado/inputText", to: await MainActor.run { PomeradoInputTextHandler() })
        await server.appendRoute("POST /pomerado/swipe", to: await MainActor.run { PomeradoSwipeHandler() })
        await server.appendRoute("POST /pomerado/screenshot", to: await MainActor.run { PomeradoScreenshotHandler() })
        await server.appendRoute("POST /pomerado/launchApp", to: await MainActor.run { PomeradoLaunchAppHandler() })
        await server.appendRoute("POST /pomerado/clearField", to: await MainActor.run { PomeradoClearFieldHandler() })
        await server.appendRoute("POST /pomerado/adjustElement", to: await MainActor.run { PomeradoAdjustHandler() })
        await server.appendRoute("POST /pomerado/pinch", to: await MainActor.run { PomeradoPinchHandler() })

        try await server.run()
    }
}
