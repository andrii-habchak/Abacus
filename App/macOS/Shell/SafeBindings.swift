import SwiftUI

// Bindings that never trap (S1, D54). SwiftUI keeps a dismissed sheet's or a removed row's
// controls alive for a moment (dismiss animation, focus resign, Escape) and they still read their
// bindings. `Binding($optional)` force-unwraps on every read and `ForEach($array)` reads by index,
// so a draft set to nil (saved, cancelled) or a row removed while its field is focused crashed
// the app (`BindingOperations.ForceUnwrapping`, index out of range). These read a fallback
// instead and drop writes that have nowhere to go.

/// A non-optional binding to an optional value held by a model: reads the value, or `fallback`
/// (the last value the view showed) once it is gone; writes only while there is a value.
@MainActor
func presentBinding<Value>(
  _ get: @escaping () -> Value?, _ set: @escaping (Value) -> Void, fallback: Value
) -> Binding<Value> {
  Binding(
    get: { get() ?? fallback },
    set: { value in
      guard get() != nil else { return }
      set(value)
    })
}

/// A binding to the element of `get()` with `id`: found by id on every read and write (never by
/// a stale index); reads `fallback` and drops writes once the element is gone.
@MainActor
func elementBinding<Element: Identifiable>(
  _ get: @escaping () -> [Element], _ set: @escaping ([Element]) -> Void, id: Element.ID, fallback: Element
) -> Binding<Element> {
  Binding(
    get: { get().first { $0.id == id } ?? fallback },
    set: { value in
      var elements = get()
      guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
      elements[index] = value
      set(elements)
    })
}
