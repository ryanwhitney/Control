import SwiftUI

struct CustomSlider: View {
    @State private var normalValue: Double = 50
    @State var sliderWidth: CGFloat = 50.0
    @State private var value: Double = 50
    @State private var isEditing = false
    private let circleSize: CGFloat = 100
    @State private var offset = CGSize.zero
    @State private var dragStartValue: Double = 0 // Store initial value when drag starts

    var dragGesture: some Gesture {
        DragGesture()
            .onChanged { gesture in
                // Update offset for visual feedback
                offset = CGSize(
                    width: gesture.startLocation.x + gesture.translation.width - circleSize/2,
                    height: gesture.startLocation.y + gesture.translation.height - circleSize/2
                )

                // Calculate what percentage of the slider width the translation represents
                let translationPercentage = gesture.translation.width / sliderWidth

                // Calculate value change based on the full range (1-100)
                let valueChange = translationPercentage * 99 // 99 represents the range from 1 to 100

                // Update value based on starting value and translation
                var newValue = dragStartValue + valueChange

                // Clamp the value between 1 and 100
                newValue = max(1, min(100, newValue))

                // Update the value
                value = newValue
            }
            .onEnded { _ in
                // Update dragStartValue to the current value when drag ends
                dragStartValue = value
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
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Layout")
        .onPreferenceChange(SizePreferenceKey.self) { newSize in
            print("The new child size is: \(newSize)")
            sliderWidth = newSize.width
        }
        .onAppear {
            dragStartValue = value
        }

    }



}
#Preview {
    CustomSlider()
}
