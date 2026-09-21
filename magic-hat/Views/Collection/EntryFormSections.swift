//
//  EntryFormSections.swift
//  magic-hat
//
//  The fields an owned row has — quantity, finish, language, condition,
//  purchase price — as Form sections, shared by the Add sheet and the row
//  editor. Purchase price defaults to Scryfall's market price for the chosen
//  finish and follows finish/printing changes until the user types a price.
//

import SwiftUI

struct EntryFormState: Equatable {
    var quantity: Int = 1
    var finish: CardFinish = .normal
    var condition: String = CardCondition.nearMint.rawValue
    var language: String = "en"
    var price: Double?
    /// Once the user has typed a price, stop following the market price.
    var priceEdited = false

    init(quantity: Int = 1, finish: CardFinish = .normal, condition: String = CardCondition.nearMint.rawValue,
         language: String = "en", price: Double? = nil, priceEdited: Bool = false) {
        self.quantity = quantity
        self.finish = finish
        self.condition = condition
        self.language = language
        self.price = price
        self.priceEdited = priceEdited
    }
}

struct EntryFormSections: View {
    @Binding var form: EntryFormState
    let printing: PrintingSelection

    private var priceBinding: Binding<Double?> {
        Binding(
            get: { form.price },
            set: { form.price = $0; form.priceEdited = true }
        )
    }

    private var marketPrice: Double? { printing.marketPrice(for: form.finish) }

    var body: some View {
        Section("Details") {
            Stepper(value: $form.quantity, in: 1...999) {
                HStack {
                    Text("Quantity")
                    Spacer()
                    Text("\(form.quantity)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("entry-quantity")

            Picker("Finish", selection: $form.finish) {
                ForEach(CardFinish.allCases, id: \.self) { finish in
                    Text(finish.displayName).tag(finish)
                }
            }
            .pickerStyle(.segmented)

            Picker("Language", selection: $form.language) {
                ForEach(CardLanguage.codes, id: \.self) { code in
                    Text(CardLanguage.name(code)).tag(code)
                }
            }

            Picker("Condition", selection: $form.condition) {
                ForEach(CardCondition.allCases) { condition in
                    Text(condition.displayName).tag(condition.rawValue)
                }
            }
        }

        Section {
            HStack {
                TextField("Purchase price", value: priceBinding, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("entry-price")
                if form.priceEdited || form.price != marketPrice {
                    Button("Market") {
                        form.price = marketPrice
                        form.priceEdited = false
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(marketPrice == nil)
                }
            }
        } header: {
            Text("Purchase price")
        } footer: {
            Text(marketPrice.map { "Scryfall market for \(form.finish.displayName.lowercased()): \(PriceFormat.string($0))" }
                 ?? "No Scryfall price for this finish yet.")
        }
        .onChange(of: form.finish) { _, _ in
            if !form.priceEdited { form.price = marketPrice }
        }
        .onChange(of: printing) { _, _ in
            if !form.priceEdited { form.price = marketPrice }
        }
    }
}
