import Vapor

extension Application {
    // MVP: MacroService is currently instantiated directly in the controller.
    // We will move to app.macroService once we introduce real providers + DI.
}
