import SwiftUI
import Combine

struct WooglySlider: View {
    @State private var normalValue: Double = 50
    @State var sliderWidth: CGFloat = 50.0
    @State private var value: Double = 50
    @State private var isEditing = false
    @State private var dragStartValue: Double = 0

    // For inertia effect
    @State private var velocity: Double = 0
    @State private var animationTimer: AnyCancellable?
    @State private var lastUpdateTime: Date = Date()
    @State private var previousTranslation: CGFloat = 0

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { gesture in
                // Calculate time since last update for velocity
                let currentTime = Date()
                let timeDelta = currentTime.timeIntervalSince(lastUpdateTime)

                // Calculate velocity (points per second)
                if timeDelta > 0 {
                    let translationDelta = gesture.translation.width - previousTranslation
                    velocity = Double(translationDelta / CGFloat(timeDelta))
                }

                // Update tracking variables
                previousTranslation = gesture.translation.width
                lastUpdateTime = currentTime

                // Calculate what percentage of the slider width the translation represents
                let translationPercentage = gesture.translation.width / sliderWidth

                // Calculate value change based on the full range (1-100)
                let valueChange = translationPercentage * 99

                // Update value based on starting value and translation
                var newValue = dragStartValue + valueChange

                // Clamp the value between 1 and 100
                newValue = max(1, min(100, newValue))

                // Update the value
                value = newValue

                // Cancel any existing inertia animation
                animationTimer?.cancel()
            }
            .onEnded { _ in
                // Update dragStartValue to the current value when drag ends
                dragStartValue = value

                // Determine if we should apply inertia based on velocity
                // Higher threshold makes it less sensitive to quick swipes
                if abs(velocity) > 300 { // Increased threshold
                    startInertiaAnimation()
                }

                // Reset velocity tracking
                previousTranslation = 0
            }
    }

    func startInertiaAnimation() {
        // Cancel any existing timer
        animationTimer?.cancel()

        // Initial velocity from drag gesture
        var currentVelocity = velocity

        // Cap the maximum velocity to prevent extreme flicks
        let maxVelocity: Double = 1000
        currentVelocity = max(-maxVelocity, min(maxVelocity, currentVelocity))

        // Calculate the maximum potential distance the slider will travel
        // This ensures the slider will never move more than ~25% of its range from inertia
        let maxInertiaRange = 25.0 // Max percentage of slider range (1-100) from inertia
        let velocityDirection = currentVelocity > 0 ? 1.0 : -1.0
        let velocityMagnitude = min(abs(currentVelocity), maxVelocity)
        var scaledVelocity = velocityDirection * velocityMagnitude * (maxInertiaRange / maxVelocity)

        // Start a timer to update the value with decaying velocity
        animationTimer = Timer.publish(every: 0.016, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                // Calculate value change based on scaled velocity
                let valueChange = (scaledVelocity * 0.016) / Double(sliderWidth) * 99

                // Update value with inertia
                var newValue = value + valueChange

                // Clamp the value between 1 and 100
                newValue = max(1, min(100, newValue))

                // Update the value
                value = newValue
                dragStartValue = newValue

                // Apply stronger friction to slow down more quickly
                let friction: Double = 0.75 // Stronger friction for faster falloff
                scaledVelocity *= friction

                // Stop animation when velocity becomes very small
                if abs(scaledVelocity) < 0.5 {
                    animationTimer?.cancel()
                }
            }
    }

    struct SizePreferenceKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
    }

    var body: some View {
        VStack(spacing:16){
            Spacer()
            HStack(){
                HStack{
                    Image(systemName: "speaker.minus.fill")
                        .foregroundStyle(.blue)
                        .padding(.top, 8)
                }
                .frame(width: 30, height: 30)
                GeometryReader { geometry in
                    ZStack(alignment: .leading){
                        Slider(value: $value, in: 1...100) {
                            Text("Volume: \(Int(value))")
                        } onEditingChanged: { editing in
                            isEditing = editing
                            // Cancel inertia when user manually interacts with slider
                            if editing {
                                animationTimer?.cancel()
                            }
                        }
                        .background(
                            GeometryReader { geometryProxy in
                                Color.clear
                                    .preference(key: SizePreferenceKey.self, value: geometryProxy.size)
                            }
                        )
                        .opacity(0.02)

                        VStack{
                            HStack{
                                Color.clear
                            }
                            .cornerRadius(100)
                            .background(Color.blue)
                            .frame(width: geometry.size.width * value * 0.01, height: 23, alignment: .leading)
                        }
                        .frame(width: geometry.size.width, height: 23, alignment: .leading)
                        .background(Color(red: 0.14, green: 0.14, blue: 0.145))
                        .gesture(dragGesture)
                        .cornerRadius(100)
                        .animation(.interpolatingSpring(stiffness: 100, damping: 20), value: value)
                    }
                }
                HStack{
                    Image(systemName: "speaker.plus.fill")
                        .foregroundStyle(.blue)
                        .padding(.top, 8)
                }
                .frame(width: 30, height: 30)
            }
            .frame(height: 23)
            Spacer()
            Slider(value: $normalValue, in: 1...100) {
                Text("Volume: \(Int(normalValue))")
            } onEditingChanged: { editing in
                isEditing = editing
            }

            Spacer()
            Text("Current value: \(Int(value))")
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Layout")
        .onPreferenceChange(SizePreferenceKey.self) { newSize in
            sliderWidth = newSize.width
        }
        .onAppear {
            dragStartValue = value
            lastUpdateTime = Date()
        }
        .onDisappear {
            animationTimer?.cancel()
        }
    }
}

#Preview {
    WooglySlider()
}
