# SHOPPING-107 simulator captures

These are actual Shopping UI captures from the iPhone 17 Pro simulator running iOS 26.5 at 402 × 874 points. The app was launched with the `populated` or `largeText` preview fixture by the focused `ShoppingDeviceUITests` cases.

- [All six groceries](all-six.png): default text, four category groups, Michael and “Low sugar” on Granola, and the one-time Birthday candles note. The final note clears the tab bar.
- [Costco](costco.png): three sparse category groups with purchase-rule symbols. Single-item sections have no separator below the row.
- [Costco with quantity](costco-quantity.png): Granola has a person, note, store symbol, and quantity controls on the title line.
- [Accessibility XXXL](accessibility-xxxl.png): the list grows and scrolls; metadata remains distinct and quantity buttons remain reachable.
- [Accessibility final note clear](accessibility-final-note-clear.png): after scrolling, the final line of a long one-time note and its quantity controls sit fully above the floating tab bar at XXXL.

The `ShoppingDeviceUITests` cases assert the final note's position, metadata and store eligibility, 44-point quantity targets, and title-to-control center alignment. The XXXL test also scrolls until the long note and quantity controls clear the tab bar. `ShoppingFast` passed 215 tests. More scrolling at accessibility sizes is expected.
