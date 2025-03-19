import SwiftUI

struct CustomSlider: View {
    @State var sliderWidth: CGFloat = 50.0
    @State private var value: Double = 50
    @State private var isEditing = false

    struct SizePreferenceKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
    }

    var body: some View {
        VStack(spacing:16){
            Spacer()
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
                        .cornerRadius(10)
                        .background(Color.blue)
                        .frame(width: geometry.size.width * value * 0.01, height: 40, alignment: .leading)
                    }
                    .frame(width: geometry.size.width, height: 40, alignment: .leading)
                    .background(Color(red: 0.14, green: 0.14, blue: 0.145))
                    .allowsHitTesting(false)
                    .cornerRadius(10)
                    .padding(.horizontal, 10)
                }
            }
            .frame(height: 40)
            Spacer()
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
                    .opacity(0.1)

                    VStack{
                        HStack{
                            Color.clear
                        }
                        .cornerRadius(10)
                        .background(Color.blue)
                        .frame(width: geometry.size.width * value * 0.01, height: 40, alignment: .leading)
                    }
                    .frame(width: geometry.size.width, height: 40, alignment: .leading)
                    .background(Color(red: 0.14, green: 0.14, blue: 0.145))
                    .allowsHitTesting(false)
                    .cornerRadius(10)
                }
            }
            .frame(height: 40)

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
                        .opacity(0.1)

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
                        .allowsHitTesting(false)
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
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarTitle("Layout")
        .onPreferenceChange(SizePreferenceKey.self) { newSize in
            print("The new child size is: \(newSize)")
            sliderWidth = newSize.width
        }
        .frame(maxWidth: 393)

    }



}
#Preview {
    CustomSlider()
}
