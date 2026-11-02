// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

@main
enum BandejaApplication {
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let appDelegate = AppDelegate()
        delegate = appDelegate
        application.delegate = appDelegate
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        self.controller = controller
        buildMenus(controller)
        controller.present()
        if !pendingFiles.isEmpty {
            controller.importFiles(pendingFiles)
            pendingFiles = []
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.present()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let controller {
            controller.present()
            controller.importFiles(urls)
        } else {
            pendingFiles.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func buildMenus(_ controller: MainWindowController) {
        let main = NSMenu()
        let application = NSMenu(title: "Bandeja PDF")
        application.addItem(withTitle: "Acerca de Bandeja PDF", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Ocultar Bandeja PDF", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(.separator())
        application.addItem(withTitle: "Salir de Bandeja PDF", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addMenu(application, to: main)

        let file = NSMenu(title: "Archivo")
        addItem("Abrir PDF…", action: #selector(MainWindowController.openPDF(_:)), key: "o", target: controller, to: file)
        addItem("Guardar PDF…", action: #selector(MainWindowController.exportPDF(_:)), key: "s", target: controller, to: file)
        addItem("Imprimir…", action: #selector(MainWindowController.printPDF(_:)), key: "p", target: controller, to: file)
        file.addItem(.separator())
        addItem("Mostrar bandejas", action: #selector(MainWindowController.showTrays(_:)), key: "", target: controller, to: file)
        file.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addMenu(file, to: main)

        let edit = NSMenu(title: "Edición")
        addItem("Deshacer cambio de páginas", action: #selector(MainWindowController.undoPages(_:)), key: "z", target: controller, to: edit)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        addItem("Buscar en el PDF", action: #selector(MainWindowController.focusSearch(_:)), key: "f", target: controller, to: edit)
        addItem("Unir documentos seleccionados", action: #selector(MainWindowController.mergeDocuments(_:)), key: "", target: controller, to: edit)
        addItem("Eliminar documentos…", action: #selector(MainWindowController.deleteDocuments(_:)), key: "", target: controller, to: edit)
        addMenu(edit, to: main)

        let view = NSMenu(title: "Visualización")
        addItem("Aumentar", action: #selector(MainWindowController.zoomIn(_:)), key: "+", target: controller, to: view)
        addItem("Reducir", action: #selector(MainWindowController.zoomOut(_:)), key: "-", target: controller, to: view)
        addItem("Ajustar a la ventana", action: #selector(MainWindowController.fitPage(_:)), key: "0", target: controller, to: view)
        addMenu(view, to: main)

        let window = NSMenu(title: "Ventana")
        window.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Ampliar", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        addMenu(window, to: main)
        NSApplication.shared.windowsMenu = window
        NSApplication.shared.mainMenu = main
    }

    private func addMenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem()
        item.submenu = menu
        main.addItem(item)
    }

    private func addItem(_ title: String, action: Selector, key: String, target: AnyObject, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
    }
}
