# Shopping

A personal iOS grocery app built around how I actually shop: I go to 1-3 stores and buy specific things at specific stores. The core idea is a **persistent item catalog** that learns where I buy things and builds up over time.

## The Problem

I manage store-based grocery lists in Paprika 3 but it's clunky. The knowledge of "where to buy what" lives in my head:

- Bananas: anywhere
- Granola: Costco only
- Canned chipotles: Publix only
- Dinner rolls: Walmart or Costco, not Aldi or Publix or Ingles

I want an app that captures this knowledge and uses it to build smart per-store shopping lists.

## Core Concepts

### Item Catalog

A central, persistent database of items that grows as I use the app. Each item knows which stores carry it. When I edit an item (change tags, add a store, update category), those changes persist — next time I see that item, it reflects everything I've learned about it.

### Store Tagging

Every item is tagged with one or more stores where it can be purchased. A special **any-store** flag means the item shows up on every shopping list regardless of store. When I build a list for Costco, I only see items tagged for Costco (plus any-store items).

### Shopping Lists

A shopping list is tied to a specific store and a specific trip. I pick a store, the app shows me items I can buy there, I pick what I need, and I check them off as I shop.

### Sharing

My wife and I share the same item catalog and shopping lists. She can add items, build lists, and check things off. Implemented via iCloud (CloudKit shared zones) — no server to maintain.

## Tech Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| UI | SwiftUI | Declarative, modern iOS UI framework |
| Persistence | SwiftData | Apple's native ORM, works directly with Swift types |
| Sync & Sharing | CloudKit (via SwiftData) | Built-in sync and multi-user sharing, no backend server |
| Distribution | TestFlight | Requires Apple Developer account ($99/yr) |

SwiftData has built-in CloudKit integration, so local persistence, cloud sync, and multi-user sharing all come from one framework.

## Data Model

```
Store
  name: String              // "Costco", "Aldi", "Publix"
  sortOrder: Int             // display ordering

Item
  name: String              // "Bananas", "Canned Chipotles"
  stores: [Store]           // which stores carry this (many-to-many)
  anyStore: Bool            // true = appears on every shopping list
  category: String?         // "Produce", "Canned Goods" — for grouping in-store
  notes: String?            // "get the La Costena brand"

ShoppingList
  store: Store              // the store this trip is for
  date: Date
  items: [ShoppingListItem]

ShoppingListItem
  item: Item                // reference back to the master catalog
  quantity: Int
  checked: Bool             // crossed off in-store
```

### Key Relationships

- An **Item** can belong to many **Stores**, and a **Store** can have many **Items** (many-to-many).
- A **ShoppingListItem** is a lightweight wrapper that references a master catalog **Item**. Edits to the Item propagate everywhere.
- A **ShoppingList** is scoped to one **Store**. It shows items where `item.stores` contains that store OR `item.anyStore == true`.

## UX Flows

### First-Time Item Creation
Search the catalog, item doesn't exist yet, create it, tag with store(s) or mark as any-store. It's now in the catalog permanently.

### Building a Shopping List
Pick a store. See all items available at that store. Tap to add what I need for this trip.

### Shopping
Checklist UI. Check items off as I grab them.

### Item Evolution
Discover Aldi now carries granola — edit the item, add the Aldi tag, it now appears on future Aldi lists.

## Project Structure

```
Shopping/
  App/
    ShoppingApp.swift              // @main, SwiftData container setup
  Models/
    Store.swift
    Item.swift
    ShoppingList.swift
    ShoppingListItem.swift
  Views/
    StoreListView.swift            // manage stores
    ItemCatalogView.swift          // browse/edit master item list
    ShoppingListView.swift         // active shopping list for a trip
    AddItemView.swift              // add item to list (search catalog + create new)
  CloudKit/
    SharingController.swift        // CloudKit share invitation UI
```

## Setup Requirements

- **Xcode** (free, Mac App Store)
- **Apple Developer Account** ($99/yr, required for CloudKit and TestFlight)
- iOS 17+ deployment target (for SwiftData)

## Status

Planning phase. No code yet.
