// On Apple platforms the models use Combine / SwiftUI's ObservableObject. Linux has no Combine, so a tiny shim lets
// the same model code compile and be unit tested there. (Nothing observes on Linux; it only has to type check.)
#if canImport(Combine)
@_exported import Combine
#else
public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif
