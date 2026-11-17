// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct FM1DockApp: App {
	@State private var app = AppModel()
	@State private var path: [Route] = []

	var body: some Scene {
		WindowGroup {
			NavigationStack(path: $path) {
				HomeView(path: $path)
					.navigationDestination(for: Route.self) { route in
						switch route {
						case let .site(site): BrowserView(site: site)
						case .library: LibraryView()
						case .hands: HandsView()
						#if FM1_DOCK
						case let .rig(id): RigDetailView(id: id)
						case .catalogue: CatalogueView()
						#endif
						}
					}
			}
			.environment(app)
			.onChange(of: app.requestedRoute) {
				if let r = app.requestedRoute { path = [r]; app.requestedRoute = nil }
			}
			#if FM1_DOCK
			// a .fwsc or .dock opened in the app (Files, Safari, Mail): into the library
			.onOpenURL { url in
				guard url.isFileURL else { return }
				app.library.add([url])
				if path.isEmpty { path.append(.library) }   // (never over a page: an install there would stop)
			}
			#endif
		}
	}
}
