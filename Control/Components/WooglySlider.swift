import SwiftUI
import Combine

struct WooglySlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: ((Bool) -> Void)?
    @State private var sliderWidth: CGFloat = 50.0
    @State private var isExpanded = false
    @State private var isAnimating = false
    @State private var dragStartValue: Double = 0
    
    // For inertia effect
    @State private var velocity: Double = 0
    @State private var animationTimer: AnyCancellable?
    @State private var lastUpdateTime: Date = Date()
    @State private var previousTranslation: CGFloat = 0
    
    init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, step: Double? = nil, onEditingChanged: ((Bool) -> Void)? = nil) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }
    
    var sliderGesture: some Gesture {
        SequenceGesture(
            LongPressGesture(minimumDuration: 0.0)
                .onEnded { _ in
                    isExpanded = true
                    isAnimating = true
                    onEditingChanged?(true)
                },
            DragGesture(minimumDistance: 0)  // Allow drag detection without movement
                .onChanged { gesture in
                    let currentTime = Date()
                    let timeDelta = currentTime.timeIntervalSince(lastUpdateTime)
                    
                    if timeDelta > 0 {
                        let translationDelta = gesture.translation.width - previousTranslation
                        velocity = Double(translationDelta / CGFloat(timeDelta))
                    }
                    
                    previousTranslation = gesture.translation.width
                    lastUpdateTime = currentTime
                    
                    let translationPercentage = gesture.translation.width / sliderWidth
                    let rangeSize = range.upperBound - range.lowerBound
                    let valueChange = translationPercentage * rangeSize
                    
                    var newValue = dragStartValue + valueChange
                    newValue = max(range.lowerBound, min(range.upperBound, newValue))
                    
                    if let step = step {
                        newValue = (newValue / step).rounded() * step
                    }
                    
                    value = newValue
                    onEditingChanged?(true)
                    animationTimer?.cancel()
                }
                .onEnded { _ in
                    dragStartValue = value
                    onEditingChanged?(false)
                    
                    if abs(velocity) > 300 {
                        startInertiaAnimation()
                    } else {
                        isExpanded = false
                        isAnimating = false
                    }
                    
                    previousTranslation = 0
                }
        )
    }

    func startInertiaAnimation() {
        animationTimer?.cancel()
        isAnimating = true
        isExpanded = true
        
        var currentVelocity = velocity
        let maxVelocity: Double = 1000
        currentVelocity = max(-maxVelocity, min(maxVelocity, currentVelocity))
        
        let maxInertiaRange = (range.upperBound - range.lowerBound) * 0.25
        let velocityDirection = currentVelocity > 0 ? 1.0 : -1.0
        let velocityMagnitude = min(abs(currentVelocity), maxVelocity)
        var scaledVelocity = velocityDirection * velocityMagnitude * (maxInertiaRange / maxVelocity)
        
        animationTimer = Timer.publish(every: 0.016, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let valueChange = (scaledVelocity * 0.016) / Double(sliderWidth) * (range.upperBound - range.lowerBound)
                
                var newValue = value + valueChange
                newValue = max(range.lowerBound, min(range.upperBound, newValue))
                
                if let step = step {
                    newValue = (newValue / step).rounded() * step
                }
                
                value = newValue
                dragStartValue = newValue
                
                let friction: Double = 0.75
                scaledVelocity *= friction
                
                if abs(scaledVelocity) < 0.5 {
                    animationTimer?.cancel()
                    onEditingChanged?(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isExpanded = false
                        isAnimating = false
                    }
                }
            }
    }

    struct SizePreferenceKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Hidden slider for accessibility
                Slider(
                    value: $value,
                    in: range,
                    step: step ?? (range.upperBound - range.lowerBound) / 100
                ) { 
                    Text("Volume \(value)")
                } onEditingChanged: { editing in
                    onEditingChanged?(editing)
                    if editing {
                        animationTimer?.cancel()
                    }
                }
                .opacity(0.02)
                .blendMode(.darken)

                // Custom slider visualization
                VStack {
                    HStack {
                        Color.clear
                    }
                    .cornerRadius(100)
                    .background(Color.accentColor)
                    .frame(
                        width: geometry.size.width * 
                            ((value - range.lowerBound) / (range.upperBound - range.lowerBound)),
                        height: 28,
                        alignment: .leading
                    )
                }
                .frame(width: geometry.size.width, height: isExpanded ? 28 : 10, alignment: .leading)
                .background(.quaternary)
                .gesture(sliderGesture)
                .clipShape(.capsule)
                .animation(.interpolatingSpring(stiffness: 100, damping: 20), value: value)
                .animation(.spring(response: 0.4, dampingFraction: 0.5), value: isAnimating)
            }
            .background(
                GeometryReader { geometryProxy in
                    Color.clear.preference(key: SizePreferenceKey.self, value: geometryProxy.size)
                }
            )
        }
        .frame(height: 28)
        .onPreferenceChange(SizePreferenceKey.self) { newSize in
            sliderWidth = newSize.width
        }
        .onAppear {
            dragStartValue = value
            lastUpdateTime = Date()
        }
        .onChange(of: value) { _, newValue in
            // Update dragStartValue when the remote volume changes
            if !isAnimating && !isExpanded {  // Only update when we're not interacting
                dragStartValue = newValue
            }
        }
        .onDisappear {
            animationTimer?.cancel()
        }
    }
}

#Preview {
    @Previewable @State var value: Double = 50.0
    WooglySlider(value: $value, in: 0...100)
}
