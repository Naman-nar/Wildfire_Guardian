//
// ContentView.swift
// Wildfire Guardian
//
// Created by Naman Narang on 10/29/25.
//
// Privacy: This app uses location services only to show
// nearby wildfire risks and shelters. No data is collected
// or transmitted to third parties except API requests.
//
//Disclosure:
//We used ChatGPT (Perplexity AI) as a coding assistant to help develop this app.
//What AI Helped With:
//Improving Code readability
//
//Debugging assistance
//
//API integration support (NASA FIRMS)
//
//UI/UX improvement

import SwiftUI
import GoogleGenerativeAI
import MapKit
import Combine
import CoreLocation

// MARK: - Gemini Configuration
//Demo Keys - would be stored securely in actual production
let GEMINI_API_KEY = "AIzaSyBlByVQ2vYjD0OpHYBLmYdOZ9rgHRBowfM"
let geminiModel = GenerativeModel(name: "gemini-2.0-flash-exp", apiKey: GEMINI_API_KEY)

// MARK: - NASA FIRMS Configuration
//Demo Keys - would be stored securely in actual production
let NASA_FIRMS_API_KEY = "4d314a9755f1643a7ce6bbe3c2ce29be"

enum GeminiError: Error {
    case emptyResponse
}

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    @Published var userLocation: CLLocationCoordinate2D?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var locationError: String?
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestLocation() {
        authorizationStatus = manager.authorizationStatus
        
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            locationError = "Location access denied. Enable in Settings."
        @unknown default:
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.userLocation = location.coordinate
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.locationError = "Failed to get location: \(error.localizedDescription)"
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if self.authorizationStatus == .authorizedWhenInUse || self.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

// MARK: - Evacuation Status Models
enum EvacuationStatus {
    case safe, monitor, warning, evacuateNow, unknown
    
    var title: String {
        switch self {
        case .safe: return "All Clear"
        case .monitor: return "Monitor Conditions"
        case .warning: return "Evacuation Warning"
        case .evacuateNow: return "EVACUATE NOW"
        case .unknown: return "Status Unknown"
        }
    }
    
    var message: String {
        switch self {
        case .safe: return "No active threats in your area"
        case .monitor: return "Fire detected nearby - stay alert"
        case .warning: return "Be ready to evacuate immediately"
        case .evacuateNow: return "Leave the area immediately"
        case .unknown: return "Enable location to check status"
        }
    }
    
    var color: Color {
        switch self {
        case .safe: return .green
        case .monitor: return .yellow
        case .warning: return .orange
        case .evacuateNow: return .red
        case .unknown: return .gray
        }
    }
    
    var icon: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .monitor: return "eye.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .evacuateNow: return "exclamationmark.octagon.fill"
        case .unknown: return "location.slash.fill"
        }
    }
}

class EvacuationStatusViewModel: ObservableObject {
    @Published var evacuationStatus: EvacuationStatus = .unknown
    @Published var nearestFireDistance: Double?
    @Published var activeFiresNearby: Int = 0
    @Published var isLoading: Bool = false
    
    func updateStatus(userLat: Double, userLon: Double, riskAssessment: RiskAssessment?) {
        guard let assessment = riskAssessment else {
            evacuationStatus = .unknown
            return
        }
        
        nearestFireDistance = assessment.nearestFireDistance
        activeFiresNearby = assessment.activeFiresNearby
        
        switch assessment.riskLevel {
        case .extreme: evacuationStatus = .evacuateNow
        case .veryHigh: evacuationStatus = .warning
        case .high, .moderate: evacuationStatus = .monitor
        case .low, .veryLow: evacuationStatus = .safe
        }
    }
}


// MARK: - Chat Message Model
struct ChatMessage: Identifiable {
    let id = UUID()
    let content: String
    let isFromUser: Bool
    let timestamp = Date()
}

// MARK: - User Profile for Iris
struct WildfireUserProfile {
    var name: String
    var phone: String
    var emergencyContact: String
    var emergencyContactNumber: String
    var address: String
    var medicalConditions: String
    var pets: String
    
    var promptRepresentation: String {
        var components: [String] = []
        
        if !name.isEmpty {
            components.append("User's name is \(name).")
        }
        if !address.isEmpty {
            components.append("User's address: \(address).")
        }
        if !medicalConditions.isEmpty {
            components.append("Medical conditions: \(medicalConditions). This is critical for emergency advice.")
        }
        if !pets.isEmpty {
            components.append("Pets/Dependents: \(pets). Include them in evacuation planning.")
        }
        if !emergencyContact.isEmpty {
            components.append("Emergency contact: \(emergencyContact) at \(emergencyContactNumber).")
        }
        
        guard !components.isEmpty else {
            return "No user profile data available."
        }
        
        return "User Profile Information:\n" + components.joined(separator: "\n")
    }
}

// MARK: - Active Fire Model
struct ActiveFire: Codable, Identifiable, Equatable {
    var id = UUID()
    let latitude: Double
    let longitude: Double
    let brightness: Double?
    let acq_date: String?
    let confidence: String?
    
    enum CodingKeys: String, CodingKey {
        case latitude, longitude, brightness, acq_date, confidence
    }
}

// MARK: - Wildfire Risk Assessment
enum WildfireRiskLevel: String, Equatable {
    case veryLow = "Very Low"
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"
    case veryHigh = "Very High"
    case extreme = "Extreme"
    
    var color: Color {
        switch self {
        case .veryLow: return .green
        case .low: return .green
        case .moderate: return .yellow
        case .high: return .orange
        case .veryHigh: return .red
        case .extreme: return .purple
        }
    }
    
    var icon: String {
        switch self {
        case .veryLow, .low: return "checkmark.shield.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .high, .veryHigh: return "flame.fill"
        case .extreme: return "exclamationmark.octagon.fill"
        }
    }
}

struct RiskAssessment: Equatable {
    let riskLevel: WildfireRiskLevel
    let nearestFireDistance: Double?
    let activeFiresNearby: Int
    let recommendations: [String]
}

// MARK: - Emergency Preparedness Models

struct ChecklistItem: Identifiable, Codable {
    let id: UUID
    var name: String
    let category: String
    var isChecked: Bool
    var isCustom: Bool
    
    init(id: UUID = UUID(), name: String, category: String, isChecked: Bool = false, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.category = category
        self.isChecked = isChecked
        self.isCustom = isCustom
    }
}

struct EducationTopic: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let color: Color
    let content: String
}

class PreparednessViewModel: ObservableObject {
    @Published var checklistItems: [ChecklistItem] = []
    @Published var selectedCategory: String = "All"
    @Published var showAddItemSheet: Bool = false
    @Published var newItemName: String = ""
    @Published var newItemCategory: String = "Supplies"
    
    let categories = ["All", "Documents", "Supplies", "Medical", "Pet Care", "Clothing"]
    
    init() {
        loadDefaultChecklist()
    }
    
    func loadDefaultChecklist() {
        checklistItems = [
            // Documents
            ChecklistItem(name: "Driver's License / ID copies", category: "Documents"),
            ChecklistItem(name: "Insurance policies", category: "Documents"),
            ChecklistItem(name: "Medical records", category: "Documents"),
            ChecklistItem(name: "Bank account information", category: "Documents"),
            ChecklistItem(name: "Property deed/rental agreement", category: "Documents"),
            ChecklistItem(name: "Birth certificates", category: "Documents"),
            ChecklistItem(name: "Social Security cards", category: "Documents"),
            
            // Supplies
            ChecklistItem(name: "Water (1 gallon/person/day for 3 days)", category: "Supplies"),
            ChecklistItem(name: "Non-perishable food (3-day supply)", category: "Supplies"),
            ChecklistItem(name: "Flashlight with extra batteries", category: "Supplies"),
            ChecklistItem(name: "Battery-powered/hand crank radio", category: "Supplies"),
            ChecklistItem(name: "Phone charger & power bank", category: "Supplies"),
            ChecklistItem(name: "Cash ($200-500)", category: "Supplies"),
            ChecklistItem(name: "Maps of local area", category: "Supplies"),
            ChecklistItem(name: "Multi-tool or knife", category: "Supplies"),
            ChecklistItem(name: "Matches/lighter in waterproof container", category: "Supplies"),
            
            // Medical
            ChecklistItem(name: "First aid kit", category: "Medical"),
            ChecklistItem(name: "Prescription medications (7-day supply)", category: "Medical"),
            ChecklistItem(name: "Over-the-counter medications", category: "Medical"),
            ChecklistItem(name: "Glasses/contact lenses", category: "Medical"),
            ChecklistItem(name: "Medical equipment (hearing aids, etc.)", category: "Medical"),
            ChecklistItem(name: "N95 masks", category: "Medical"),
            
            // Pet Care
            ChecklistItem(name: "Pet food & water (3-day supply)", category: "Pet Care"),
            ChecklistItem(name: "Pet medications", category: "Pet Care"),
            ChecklistItem(name: "Pet carrier/leash", category: "Pet Care"),
            ChecklistItem(name: "Pet medical records & photos", category: "Pet Care"),
            ChecklistItem(name: "Litter box/waste bags", category: "Pet Care"),
            
            // Clothing
            ChecklistItem(name: "Change of clothes", category: "Clothing"),
            ChecklistItem(name: "Sturdy shoes/boots", category: "Clothing"),
            ChecklistItem(name: "Rain jacket", category: "Clothing"),
            ChecklistItem(name: "Hat and gloves", category: "Clothing"),
            ChecklistItem(name: "Emergency blanket", category: "Clothing")
        ]
    }
    
    func toggleItem(id: UUID) {
        if let index = checklistItems.firstIndex(where: { $0.id == id }) {
            checklistItems[index].isChecked.toggle()
        }
    }
    
    func addItem() {
        guard !newItemName.isEmpty else { return }
        let newItem = ChecklistItem(name: newItemName, category: newItemCategory, isCustom: true)
        checklistItems.append(newItem)
        newItemName = ""
        showAddItemSheet = false
    }
    
    func removeItem(id: UUID) {
        checklistItems.removeAll { $0.id == id }
    }
    
    func resetToDefault() {
        loadDefaultChecklist()
    }
    
    var filteredItems: [ChecklistItem] {
        if selectedCategory == "All" {
            return checklistItems
        }
        return checklistItems.filter { $0.category == selectedCategory }
    }
    
    var completionPercentage: Int {
        let checked = checklistItems.filter { $0.isChecked }.count
        let total = checklistItems.count
        return total > 0 ? Int((Double(checked) / Double(total)) * 100) : 0
    }
}

// MARK: - Find Shelter Models

struct Shelter: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    let type: ShelterType
    let amenities: [ShelterAmenity]
    let capacity: String
    let phone: String
    let notes: String
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum ShelterType: String, CaseIterable {
    case redCross = "Red Cross"
    case shelter = "Emergency Shelter"
    case communityCenter = "Community Center"
    
    var icon: String {
        switch self {
        case .redCross: return "cross.fill"
        case .shelter: return "shield.lefthalf.filled"
        case .communityCenter: return "building.2.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .redCross: return .red
        case .shelter: return .purple
        case .communityCenter: return .blue
        }
    }
}

enum ShelterAmenity: String, CaseIterable {
    case petFriendly = "Pet Friendly"
    case medical = "Medical Services"
    case wheelchairAccessible = "Wheelchair Accessible"
    case food = "Food Provided"
    case showers = "Showers Available"
    case charging = "Phone Charging"
    case familyFriendly = "Family Friendly"
    case twentyFourSeven = "24/7 Open"
    
    var icon: String {
        switch self {
        case .petFriendly: return "pawprint.fill"
        case .medical: return "cross.case.fill"
        case .wheelchairAccessible: return "figure.roll"
        case .food: return "fork.knife"
        case .showers: return "shower.fill"
        case .charging: return "bolt.fill"
        case .familyFriendly: return "figure.2.and.child.holdinghands"
        case .twentyFourSeven: return "clock.fill"
        }
    }
}

class ShelterViewModel: ObservableObject {
    @Published var shelters: [Shelter] = []
    @Published var selectedShelter: Shelter?
    @Published var selectedAmenities: Set<ShelterAmenity> = []
    @Published var selectedTypes: Set<ShelterType> = []
    @Published var searchText: String = ""
    @Published var showFilters: Bool = false
    
    init() {
        loadCA03WildfireShelters()
    }
    
    func loadCA03WildfireShelters() {
        shelters = [
            Shelter(
                name: "Salvation Army Center of Hope",
                address: "3900 Norwood Ave, Sacramento, CA 95838",
                latitude: 38.6285,
                longitude: -121.4486,
                type: .shelter,
                amenities: [.food, .showers, .wheelchairAccessible, .charging, .medical, .twentyFourSeven],
                capacity: "130 beds (adults 18+)",
                phone: "(916) 678-8300",
                notes: "Largest permanent emergency shelter in Sacramento County. Open 24/7 year-round with case management, job prep, and counseling services."
            ),
            
            Shelter(
                name: "Fourth & Hope - Yolo County",
                address: "1901 East Beamer St, Woodland, CA 95776",
                latitude: 38.6765,
                longitude: -121.7579,
                type: .shelter,
                amenities: [.food, .showers, .wheelchairAccessible, .charging, .medical, .twentyFourSeven, .familyFriendly],
                capacity: "100 beds (60 men/40 women)",
                phone: "(530) 661-1218",
                notes: "Largest shelter in Yolo County. Year-round 24/7 emergency shelter with showers, laundry, meals, and case management."
            ),
            
            Shelter(
                name: "The Gathering Inn",
                address: "River District, Sacramento, CA 95814",
                latitude: 38.5810,
                longitude: -121.5052,
                type: .shelter,
                amenities: [.food, .showers, .wheelchairAccessible, .charging, .medical, .twentyFourSeven],
                capacity: "163 beds (adults 18+)",
                phone: "(916) 679-9640",
                notes: "Largest emergency shelter in Sacramento River District. Open 24/7 with comprehensive support services including medical care."
            ),
            
            Shelter(
                name: "SHELTER Inc.",
                address: "River District, Sacramento, CA 95814",
                latitude: 38.5815,
                longitude: -121.5048,
                type: .shelter,
                amenities: [.food, .showers, .wheelchairAccessible, .charging, .medical, .twentyFourSeven],
                capacity: "Year-round emergency shelter",
                phone: "(916) 455-2160",
                notes: "Year-round emergency shelter with case management, employment services, health checks, and individualized success plans."
            ),
            
            Shelter(
                name: "Next Move Family Shelter",
                address: "8001 Folsom Blvd, Sacramento, CA 95826",
                latitude: 38.5529,
                longitude: -121.4214,
                type: .shelter,
                amenities: [.food, .wheelchairAccessible, .charging, .medical, .familyFriendly],
                capacity: "Families with children",
                phone: "(916) 395-9000",
                notes: "Permanent family emergency shelter with direct services including housing assistance, employment support, healthcare, and education."
            ),
            
            Shelter(
                name: "American Red Cross - Sacramento",
                address: "1565 Exposition Blvd, Sacramento, CA 95815",
                latitude: 38.6077,
                longitude: -121.4140,
                type: .redCross,
                amenities: [.wheelchairAccessible, .medical, .charging, .food],
                capacity: "Opens during disasters",
                phone: "(916) 993-7070",
                notes: "Regional Red Cross headquarters. Opens emergency evacuation shelters during wildfires and disasters. Call for current active shelter locations."
            ),
            
            Shelter(
                name: "Davis Community Meals & Housing",
                address: "1111 H Street, Davis, CA 95616",
                latitude: 38.5449,
                longitude: -121.7405,
                type: .communityCenter,
                amenities: [.food, .showers, .wheelchairAccessible, .charging],
                capacity: "Day services (M-F 8 AM-2 PM)",
                phone: "(530) 756-4008",
                notes: "Permanent facility providing emergency showers, clothing, hygiene products, laundry, and meals for those in need."
            )
        ]
    }
    
    var filteredShelters: [Shelter] {
        var filtered = shelters
        
        if !selectedAmenities.isEmpty {
            filtered = filtered.filter { shelter in
                selectedAmenities.allSatisfy { shelter.amenities.contains($0) }
            }
        }
        
        if !selectedTypes.isEmpty {
            filtered = filtered.filter { shelter in
                selectedTypes.contains(shelter.type)
            }
        }
        
        if !searchText.isEmpty {
            filtered = filtered.filter { shelter in
                shelter.name.localizedCaseInsensitiveContains(searchText) ||
                shelter.address.localizedCaseInsensitiveContains(searchText) ||
                shelter.notes.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return filtered
    }
    
    func toggleAmenity(_ amenity: ShelterAmenity) {
        if selectedAmenities.contains(amenity) {
            selectedAmenities.remove(amenity)
        } else {
            selectedAmenities.insert(amenity)
        }
    }
    
    func toggleType(_ type: ShelterType) {
        if selectedTypes.contains(type) {
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
    }
    
    func clearFilters() {
        selectedAmenities.removeAll()
        selectedTypes.removeAll()
        searchText = ""
    }
    
    func openDirections(to shelter: Shelter) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: shelter.coordinate))
        mapItem.name = shelter.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
    
    func callShelter(_ phone: String) {
        let cleanedPhone = phone.filter { $0.isNumber }
        if let url = URL(string: "tel://\(cleanedPhone)") {
            UIApplication.shared.open(url)
        }
    }
}


// MARK: - Wildfire Risk View Model
class WildfireRiskViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var activeFires: [ActiveFire] = []
    @Published var riskAssessment: RiskAssessment?
    @Published var selectedLocation: String = ""
    
    private let product: String = "VIIRS_SNPP_NRT"
    private let radiusDegrees: Int = 1
    
    func fetchWildfireData(latitude: Double, longitude: Double, locationName: String) async {
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
            self.selectedLocation = locationName
        }
        
        let urlString = "https://firms.modaps.eosdis.nasa.gov/api/area/csv/\(NASA_FIRMS_API_KEY)/\(self.product)/world/\(self.radiusDegrees)/\(latitude),\(longitude)"
        
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let csvString = String(data: data, encoding: .utf8) ?? ""
            
            let fires = parseCSV(csvString)
            let assessment = calculateRiskAssessment(fires: fires, userLat: latitude, userLon: longitude)
            
            await MainActor.run {
                self.activeFires = fires
                self.riskAssessment = assessment
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to fetch data: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func parseCSV(_ csv: String) -> [ActiveFire] {
        let lines = csv.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        
        let header = lines[0].components(separatedBy: ",")
        guard let latIndex = header.firstIndex(of: "latitude"),
              let lonIndex = header.firstIndex(of: "longitude") else {
            return []
        }
        
        var fires: [ActiveFire] = []
        for line in lines.dropFirst() {
            let values = line.components(separatedBy: ",")
            guard values.count > max(latIndex, lonIndex),
                  let lat = Double(values[latIndex]),
                  let lon = Double(values[lonIndex]) else {
                continue
            }
            
            let brightness = values.count > 2 ? Double(values[2]) : nil
            let date = values.count > 5 ? values[5] : nil
            let confidence = values.count > 8 ? values[8] : nil
            
            fires.append(ActiveFire(latitude: lat, longitude: lon, brightness: brightness, acq_date: date, confidence: confidence))
        }
        
        return fires
    }
    
    private func calculateRiskAssessment(fires: [ActiveFire], userLat: Double, userLon: Double) -> RiskAssessment {
        guard !fires.isEmpty else {
            return RiskAssessment(
                riskLevel: .veryLow,
                nearestFireDistance: nil,
                activeFiresNearby: 0,
                recommendations: [
                    "No active wildfires detected in your area",
                    "Continue monitoring local fire conditions",
                    "Maintain defensible space around your property",
                    "Keep emergency supplies ready"
                ]
            )
        }
        
        var nearestDistance = Double.infinity
        var firesWithin50Miles = 0
        var firesWithin100Miles = 0
        
        for fire in fires {
            let distance = haversineDistance(lat1: userLat, lon1: userLon, lat2: fire.latitude, lon2: fire.longitude)
            nearestDistance = min(nearestDistance, distance)
            
            if distance <= 50 {
                firesWithin50Miles += 1
            }
            if distance <= 100 {
                firesWithin100Miles += 1
            }
        }
        
        let riskLevel: WildfireRiskLevel
        let recommendations: [String]
        
        if nearestDistance <= 10 {
            riskLevel = .extreme
            recommendations = [
                "âš ï¸ IMMEDIATE THREAT - Active fire within 10 miles",
                "Evacuate immediately if ordered by authorities",
                "Have go-bag packed and ready",
                "Monitor emergency alerts continuously",
                "Keep phone charged and gas tank full"
            ]
        } else if nearestDistance <= 25 {
            riskLevel = .veryHigh
            recommendations = [
                "Active fire within 25 miles - Be prepared to evacuate",
                "Pack essential items and important documents",
                "Identify evacuation routes",
                "Stay tuned to local emergency broadcasts",
                "Prepare pets and vehicles for quick departure"
            ]
        } else if nearestDistance <= 50 {
            riskLevel = .high
            recommendations = [
                "Active fire within 50 miles - Monitor closely",
                "Review your evacuation plan",
                "Gather important documents",
                "Check air quality regularly",
                "Stay informed through local news"
            ]
        } else if nearestDistance <= 100 {
            riskLevel = .moderate
            recommendations = [
                "Active fires detected within 100 miles",
                "Stay aware of changing conditions",
                "Review emergency preparedness plans",
                "Ensure smoke masks are available",
                "Monitor wind direction and speed"
            ]
        } else if firesWithin100Miles > 0 {
            riskLevel = .low
            recommendations = [
                "Distant fires detected - Low immediate risk",
                "Maintain awareness of fire season",
                "Keep defensible space maintained",
                "Update emergency contact list"
            ]
        } else {
            riskLevel = .veryLow
            recommendations = [
                "No nearby active fires detected",
                "Continue routine fire preparedness",
                "Maintain defensible space",
                "Keep emergency supplies current"
            ]
        }
        
        return RiskAssessment(
            riskLevel: riskLevel,
            nearestFireDistance: nearestDistance == Double.infinity ? nil : nearestDistance,
            activeFiresNearby: firesWithin100Miles,
            recommendations: recommendations
        )
    }
    
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadius = 3959.0
        
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
                sin(dLon / 2) * sin(dLon / 2)
        
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        
        return earthRadius * c
    }
}

// MARK: - Gemini Chat Session for Iris
class IrisChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    private var chat: Chat?
    private let userProfile: WildfireUserProfile
    
    init(userProfile: WildfireUserProfile) {
        self.userProfile = userProfile
        startNewChat()
    }
    
    func startNewChat() {
        chat = geminiModel.startChat()
        self.messages = []
        self.errorMessage = nil
        
        let greeting = "Hi! I'm Iris, your wildfire preparedness assistant. I can help you with evacuation planning, emergency supplies, safety tips, and real-time wildfire information. What would you like to know?"
        
        withAnimation(.easeOut(duration: 0.3)) {
            self.messages.append(ChatMessage(content: greeting, isFromUser: false))
        }
    }
    
    func sendUserMessage(message: String) async {
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.3)) {
                self.messages.append(ChatMessage(content: message, isFromUser: true))
            }
            self.isLoading = true
            self.errorMessage = nil
        }
        
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        do {
            let fullPrompt = buildPrompt(for: message)
            let response = try await chat!.sendMessage(fullPrompt)
            let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            guard !text.isEmpty else {
                throw GeminiError.emptyResponse
            }
            
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.messages.append(ChatMessage(content: text, isFromUser: false))
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Could not get response: \(error.localizedDescription)"
            }
            print("Gemini chat error:", error)
        }
        
        await MainActor.run {
            self.isLoading = false
        }
    }
    
    private func buildPrompt(for userMessage: String) -> String {
        var promptComponents: [String] = []
        
        promptComponents.append("""
        Your name is Iris, and you are an AI assistant specialized in wildfire preparedness and emergency response.
        You are powered by google gemini.
        
        Your primary focus areas:
        - Wildfire evacuation planning and safety
        - Emergency supply checklists (go-bags, home preparedness)
        - Creating defensible space around homes
        - Air quality and smoke safety
        - Pet and dependent evacuation
        - Real-time wildfire response advice
        - Post-wildfire recovery guidance
        
        Guidelines:
        - Provide actionable, specific advice
        - Be calm, clear, and reassuring
        - Prioritize life safety above all
        - If user has medical conditions or pets, tailor advice accordingly
        - Keep responses concise (under 150 words) unless detailed instructions are requested
        - Use bullet points for lists and steps
        - If the question is not related to wildfires or emergencies, politely redirect and ask how you can help with wildfire preparedness
        
        IMPORTANT: Do NOT use text formatting like bolding, italics, or markdown. Plain text only.
        """)
        
        let profileInfo = userProfile.promptRepresentation
        if !profileInfo.isEmpty {
            promptComponents.append(profileInfo)
        }
        
        promptComponents.append("User's question: \(userMessage)")
        
        return promptComponents.joined(separator: "\n\n")
    }
}

struct AnimatedGradientBackground: View {
    let colors: [Color] = [
        .blue,
        .green,
        .cyan,
        .teal,
        Color(red: 0.2, green: 0.6, blue: 0.8),
        Color(red: 0.1, green: 0.8, blue: 0.5)
    ]
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: colors),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Updated ContentView
struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var statusViewModel = EvacuationStatusViewModel()
    @StateObject private var riskViewModel = WildfireRiskViewModel()
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.orange.opacity(0.35),
                        Color.red.opacity(0.25),
                        Color.yellow.opacity(0.25)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                ScrollView{
                    VStack(spacing: 0) {
                        // Header
                        HStack {
                            Spacer()
                            HStack(spacing: 10) {
                                Image(systemName: "flame.fill")
                                    .foregroundColor(.orange)
                                    .font(.title2)
                                Text("Wildfire Guardian")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                            }
                            Spacer()
                            NavigationLink(destination: ProfileView()) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Circle().fill(Color.white.opacity(0.2)))
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .background(Color.black.opacity(0.15))
                        
                        // EVACUATION STATUS CARD
                        EvacuationStatusCard(
                            locationManager: locationManager,
                            statusViewModel: statusViewModel,
                            riskViewModel: riskViewModel
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 120)
                        
                        // Cards
                        VStack(spacing: 18) {
                            NavigationLink(destination: FindShelterView()) {
                                HomeCard(icon: "house.fill", title: "Find Shelter", subtitle: "Locate nearby shelters and resources", tint: .red)
                            }
                            
                            NavigationLink(destination: FirstPageView()) {
                                HomeCard(icon: "cross.case.fill", title: "Preparedness Hub", subtitle: "Guides and checklists for safety", tint: .blue)
                            }
                            
                            NavigationLink(destination: WildfireRiskView()) {
                                HomeCard(icon: "shield.lefthalf.fill", title: "Risk Assessment", subtitle: "Current risk around your location", tint: .orange)
                            }
                            
                            NavigationLink(destination: AskIrisView()) {
                                HomeCard(icon: "sparkles", title: "Ask Iris", subtitle: "Chat with your preparedness AI",   tint: .purple)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
                    }
                }
            }
        }
    }
}

struct HomeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.2))
                Image(systemName: icon)
                    .foregroundColor(tint)
            }
            .frame(width: 48, height: 48)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.9))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Emergency Preparedness Hub View

struct FirstPageView: View {
    @StateObject private var viewModel = PreparednessViewModel()
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.35),
                    Color.cyan.opacity(0.3),
                    Color.teal.opacity(0.25)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Preparedness Hub")
                            .font(.title2.bold())
                        Text("Stay Ready, Stay Safe")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "shield.checkered")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color.white.opacity(0.2))
                
                // Tab Selector
                HStack(spacing: 0) {
                    TabButton(title: "Go-Bag", icon: "bag.fill", isSelected: selectedTab == 0) {
                        selectedTab = 0
                    }
                    TabButton(title: "Plan", icon: "map.fill", isSelected: selectedTab == 1) {
                        selectedTab = 1
                    }
                    TabButton(title: "Learn", icon: "book.fill", isSelected: selectedTab == 2) {
                        selectedTab = 2
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                // Content
                TabView(selection: $selectedTab) {
                    GoBagChecklistView(viewModel: viewModel)
                        .tag(0)
                    
                    EvacuationPlanView()
                        .tag(1)
                    
                    EducationView()
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $viewModel.showAddItemSheet) {
            AddItemSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Tab Button Component
struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.white.opacity(0.9) : Color.clear)
            .foregroundColor(isSelected ? .blue : .white.opacity(0.7))
            .cornerRadius(12)
        }
    }
}

// MARK: - Go-Bag Checklist View
struct GoBagChecklistView: View {
    @ObservedObject var viewModel: PreparednessViewModel
    @State private var showResetAlert = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Progress Card
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preparation Progress")
                                .font(.headline)
                            Text("\(viewModel.completionPercentage)% Complete")
                                .font(.title.bold())
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .stroke(Color.blue.opacity(0.2), lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: CGFloat(viewModel.completionPercentage) / 100)
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(viewModel.completionPercentage)%")
                                .font(.caption.bold())
                        }
                        .frame(width: 60, height: 60)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.95))
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
                
                // Action Buttons
                HStack(spacing: 12) {
                    Button(action: {
                        viewModel.showAddItemSheet = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Item")
                                .font(.subheadline.bold())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(10)
                    }
                    
                    Button(action: {
                        showResetAlert = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reset List")
                                .font(.subheadline.bold())
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(10)
                    }
                }
                .alert("Reset Checklist", isPresented: $showResetAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        viewModel.resetToDefault()
                    }
                } message: {
                    Text("This will remove all custom items and reset all checkmarks. Are you sure?")
                }
                
                // Category Filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.categories, id: \.self) { category in
                            Button(action: {
                                viewModel.selectedCategory = category
                            }) {
                                Text(category)
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(viewModel.selectedCategory == category ? Color.blue : Color.white.opacity(0.6))
                                    .foregroundColor(viewModel.selectedCategory == category ? .white : .primary)
                                    .cornerRadius(20)
                            }
                        }
                    }
                }
                
                // Checklist Items
                VStack(spacing: 12) {
                    ForEach(viewModel.filteredItems) { item in
                        ChecklistItemRow(item: item, onToggle: {
                            viewModel.toggleItem(id: item.id)
                        }, onDelete: {
                            viewModel.removeItem(id: item.id)
                        })
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Checklist Item Row
struct ChecklistItemRow: View {
    let item: ChecklistItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(item.isChecked ? .green : .gray)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name)
                                .font(.body)
                                .foregroundColor(.primary)
                                .strikethrough(item.isChecked)
                            if item.isCustom {
                                Text("Custom")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.2))
                                    .foregroundColor(.purple)
                                    .cornerRadius(4)
                            }
                        }
                        Text(item.category)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
            
            if item.isCustom {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                        .padding(8)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.9))
        .cornerRadius(12)
    }
}

// MARK: - Add Item Sheet
struct AddItemSheet: View {
    @ObservedObject var viewModel: PreparednessViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("Item Details") {
                    TextField("Item name", text: $viewModel.newItemName)
                    
                    Picker("Category", selection: $viewModel.newItemCategory) {
                        ForEach(viewModel.categories.filter { $0 != "All" }, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                }
            }
            .navigationTitle("Add Custom Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.newItemName = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        viewModel.addItem()
                        dismiss()
                    }
                    .disabled(viewModel.newItemName.isEmpty)
                }
            }
        }
    }
}

// MARK: - Education View
struct EducationView: View {
    let educationTopics: [EducationTopic] = [
        EducationTopic(
            title: "Defensible Space",
            icon: "house.fill",
            color: .green,
            content: """
            Create a buffer zone around your home to slow or stop wildfire spread:
            
            Zone 1 (0-5 feet): Remove all dead plants, leaves, and debris. Use fire-resistant plants and materials.
            
            Zone 2 (5-30 feet): Space trees and shrubs with adequate clearance. Remove ladder fuels that allow fire to climb.
            
            Zone 3 (30-100 feet): Thin trees and vegetation. Remove dead wood and debris regularly.
            
            Keep roof and gutters clear of leaves and debris
            Trim tree branches at least 10 feet from structures
            Use non-combustible materials for decking and fencing
            """
        ),
        EducationTopic(
            title: "Air Quality & Smoke",
            icon: "aqi.medium",
            color: .orange,
            content: """
            Wildfire smoke poses serious health risks:
            
            Monitor AQI (Air Quality Index) regularly during fire season
            Unhealthy: 151-200, Very Unhealthy: 201-300, Hazardous: 301+
            
            Stay indoors when AQI exceeds 150
            Close windows and doors
            Use HEPA air filters if available
            Create a clean room with filtered air
            
            Wear N95 or P100 masks outdoors (cloth masks don't help with smoke)
            Avoid strenuous outdoor activities
            Children, elderly, and those with respiratory issues are most vulnerable
            """
        ),
        EducationTopic(
            title: "Evacuation Orders",
            icon: "exclamationmark.triangle.fill",
            color: .red,
            content: """
            Understanding emergency alerts:
            
            Evacuation Warning: Be ready to leave quickly. Pack your go-bag and stay alert.
            
            Evacuation Order: LEAVE IMMEDIATELY. Your life is in danger.
            
            Shelter-in-Place: Stay indoors with doors/windows closed. Seal gaps with wet towels.
            
            Important Tips:
            Sign up for local emergency alerts (reverse 911)
            Know multiple evacuation routes
            Have a communication plan with family
            Never ignore evacuation orders - delay can be fatal
            Check on neighbors, especially elderly or disabled
            """
        ),
        EducationTopic(
            title: "Home Hardening",
            icon: "hammer.fill",
            color: .blue,
            content: """
            Make your home more fire-resistant:
            
            Roof & Vents:
            Use Class A fire-rated roofing materials
            Install ember-resistant vents
            Screen all openings with 1/8" metal mesh
            
            Windows & Doors:
            Use dual-pane tempered glass windows
            Install weather stripping to prevent ember entry
            Use solid wood or fire-rated doors
            
            Exterior Walls & Deck:
            Use fire-resistant siding materials
            Build decks with ignition-resistant materials
            Enclose areas under decks and balconies
            
            These upgrades significantly improve survival odds.
            """
        ),
        EducationTopic(
            title: "Fire Weather",
            icon: "wind",
            color: .purple,
            content: """
            Conditions that increase wildfire danger:
            
            Red Flag Warnings indicate:
            Low humidity (usually below 15%)
            Strong winds (25+ mph gusts)
            Warm temperatures
            Dry vegetation
            
            High Risk Periods:
            Late summer through fall (fire season)
            Santa Ana winds in Southern California
            Diablo winds in Northern California
            After prolonged drought
            
            During Red Flag days:
            Avoid any outdoor burning
            Don't use power tools that create sparks
            Stay alert to changing conditions
            Keep car windows closed while driving
            """
        ),
        EducationTopic(
            title: "After the Fire",
            icon: "arrow.counterclockwise",
            color: .gray,
            content: """
            Returning home safely after evacuation:
            
            Before Entering:
            Wait for official all-clear from authorities
            Check for structural damage
            Look for gas leaks, broken water lines
            Document damage with photos for insurance
            
            Safety Hazards:
            Hot spots can reignite - stay vigilant
            Ash contains toxic chemicals - wear N95 mask
            Don't drink tap water until tested
            Watch for weakened trees and power lines
            
            Recovery:
            Contact insurance immediately
            Save all receipts for cleanup costs
            Seek mental health support if needed
            Connect with disaster relief services
            """
        )
    ]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Learn about wildfire safety and preparedness")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                ForEach(educationTopics) { topic in
                    EducationTopicCard(topic: topic)
                }
            }
            .padding()
        }
    }
}

// MARK: - Education Topic Card
struct EducationTopicCard: View {
    let topic: EducationTopic
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(topic.color.opacity(0.2))
                        Image(systemName: topic.icon)
                            .foregroundColor(topic.color)
                            .font(.title3)
                    }
                    .frame(width: 48, height: 48)
                    
                    Text(topic.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            
            if isExpanded {
                Text(topic.content)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding()
                    .background(topic.color.opacity(0.05))
            }
        }
        .background(Color.white.opacity(0.95))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Evacuation Plan View
struct EvacuationPlanView: View {
    @AppStorage("evacuation.primaryRoute") private var primaryRoute: String = ""
    @AppStorage("evacuation.secondaryRoute") private var secondaryRoute: String = ""
    @AppStorage("evacuation.meetingPoint") private var meetingPoint: String = ""
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Evacuation Steps
                VStack(alignment: .leading, spacing: 12) {
                    Text("Evacuation Checklist")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    ForEach(evacuationSteps, id: \.0) { step, description in
                        EvacuationStepCard(number: step, description: description)
                    }
                }
                
                // Routes & Meeting Points
                VStack(spacing: 16) {
                    Text("Your Evacuation Plan")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 12) {
                        PlanTextField(icon: "arrow.triangle.turn.up.right.diamond.fill", title: "Primary Route", text: $primaryRoute, placeholder: "e.g., Highway 101 North")
                        PlanTextField(icon: "arrow.triangle.2.circlepath", title: "Secondary Route", text: $secondaryRoute, placeholder: "e.g., Route 1 Coastal")
                        PlanTextField(icon: "mappin.and.ellipse", title: "Meeting Point", text: $meetingPoint, placeholder: "e.g., City Park entrance")
                    }
                }
                .padding()
                .background(Color.white.opacity(0.95))
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }
    
    let evacuationSteps = [
        (1, "Monitor emergency alerts and evacuation orders"),
        (2, "Grab your go-bag and essential documents"),
        (3, "Take prescription medications"),
        (4, "Secure pets in carriers"),
        (5, "Close all windows and doors"),
        (6, "Turn off gas, pilot lights, and utilities"),
        (7, "Leave lights on for firefighter visibility"),
        (8, "Follow designated evacuation routes"),
        (9, "Check in with emergency contacts"),
        (10, "Do NOT return until authorities say it's safe")
    ]
}

// MARK: - Evacuation Step Card
struct EvacuationStepCard: View {
    let number: Int
    let description: String
    
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.2))
                Text("\(number)")
                    .font(.headline.bold())
                    .foregroundColor(.orange)
            }
            .frame(width: 40, height: 40)
            
            Text(description)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding()
        .background(Color.white.opacity(0.9))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Plan Text Field
struct PlanTextField: View {
    let icon: String
    let title: String
    @Binding var text: String
    let placeholder: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Profile View
struct ProfileView: View {
    @AppStorage("profile.name") private var name: String = ""
    @AppStorage("profile.phone") private var phone: String = ""
    @AppStorage("profile.emergencyContact") private var emergencyContact: String = ""
    @AppStorage("profile.emergencyContactNumber") private var emergencyContactNumber: String = ""
    @AppStorage("profile.address") private var address: String = ""
    @AppStorage("profile.medicalConditions") private var medicalConditions: String = ""
    @AppStorage("profile.pets") private var pets: String = ""
    @AppStorage("profile.isProfileSaved") private var isProfileSaved: Bool = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.35),
                    Color.cyan.opacity(0.3),
                    Color.teal.opacity(0.25)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("Emergency Profile")
                            .font(.headline.bold())
                            .foregroundColor(.white)
                        Text("For faster, safer responses")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Button(action: { isProfileSaved = false }) {
                        Image(systemName: "pencil")
                            .font(.title3)
                            .foregroundColor(.white)
                            .opacity(isProfileSaved ? 1 : 0.3)
                    }
                    .disabled(!isProfileSaved)
                }
                .padding()
                .background(Color.black.opacity(0.2))
                
                ScrollView {
                    VStack(spacing: 20) {
                        if isProfileSaved {
                            // Saved profile card
                            VStack(alignment: .leading, spacing: 12) {
                                ProfileRow(label: "Name", value: name)
                                ProfileRow(label: "Phone", value: phone)
                                ProfileRow(label: "Emergency Contact", value: emergencyContact)
                                ProfileRow(label: "Contact Number", value: emergencyContactNumber)
                                ProfileRow(label: "Address", value: address)
                                if !medicalConditions.isEmpty { ProfileRow(label: "Medical Conditions", value: medicalConditions) }
                                if !pets.isEmpty { ProfileRow(label: "Pets/Dependents", value: pets) }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.95))
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
                            
                            Button(action: { isProfileSaved = false }) {
                                HStack {
                                    Image(systemName: "pencil")
                                    Text("Edit Profile").bold()
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                        } else {
                            // Editable form card
                            VStack(spacing: 14) {
                                ProfileTextField(title: "Name", text: $name, systemImage: "person.fill")
                                ProfileTextField(title: "Phone Number", text: $phone, systemImage: "phone.fill", keyboard: .phonePad)
                                ProfileTextField(title: "Emergency Contact", text: $emergencyContact, systemImage: "person.2.fill")
                                ProfileTextField(title: "Emergency Contact Number", text: $emergencyContactNumber, systemImage: "phone.arrow.up.right.fill", keyboard: .phonePad)
                                ProfileTextField(title: "Evacuation Address", text: $address, systemImage: "mappin.and.ellipse")
                                ProfileTextField(title: "Medical Conditions (optional)", text: $medicalConditions, systemImage: "cross.case.fill")
                                ProfileTextField(title: "Pets/Dependents (optional)", text: $pets, systemImage: "pawprint.fill")
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.95))
                            .cornerRadius(16)
                            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
                            
                            Button(action: {
                                isProfileSaved = true
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }) {
                                Text("Save Profile").bold()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            
                            Button(role: .destructive) {
                                name = ""
                                phone = ""
                                emergencyContact = ""
                                emergencyContactNumber = ""
                                address = ""
                                medicalConditions = ""
                                pets = ""
                                isProfileSaved = false
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text("Reset Profile")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationBarHidden(true)
    }
}

struct ProfileRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .foregroundColor(.primary)
        }
    }
}

struct ProfileTextField: View {
    let title: String
    @Binding var text: String
    let systemImage: String
    var keyboard: UIKeyboardType = .default
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(.blue)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .keyboardType(keyboard)
        }
        .padding(12)
        .background(Color.white.opacity(0.9))
        .cornerRadius(12)
    }
}

// MARK: - Wildfire Risk View
struct WildfireRiskView: View {
    @StateObject private var viewModel = WildfireRiskViewModel()
    @Environment(\.dismiss) var dismiss
    
    @State private var customLatitude: String = ""
    @State private var customLongitude: String = ""
    @State private var customLocationName: String = ""
    @State private var showCustomInput: Bool = false
    
    // Predefined locations
    let locations: [(name: String, lat: Double, lon: Double)] = [
        ("Los Angeles, CA", 34.0522, -118.2437),
        ("San Francisco, CA", 37.7749, -122.4194),
        ("San Diego, CA", 32.7157, -117.1611),
        ("Sacramento, CA", 38.5816, -121.4944),
        ("Portland, OR", 45.5152, -122.6784),
        ("Seattle, WA", 47.6062, -122.3321)
    ]
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.orange.opacity(0.3),
                    Color.red.opacity(0.2),
                    Color.yellow.opacity(0.2)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        VStack {
                            Text("Wildfire Risk")
                                .font(.title).bold()
                            Text("Assessment")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "flame.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                    }
                    .padding()
                    
                    // Location Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select Location")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(locations, id: \.name) { location in
                                    Button(action: {
                                        showCustomInput = false
                                        Task {
                                            await viewModel.fetchWildfireData(
                                                latitude: location.lat,
                                                longitude: location.lon,
                                                locationName: location.name
                                            )
                                        }
                                    }) {
                                        VStack {
                                            Image(systemName: "mappin.circle.fill")
                                                .font(.title2)
                                            Text(location.name)
                                                .font(.caption)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(width: 100, height: 80)
                                        .background(
                                            viewModel.selectedLocation == location.name ?
                                            Color.orange.opacity(0.3) : Color.white.opacity(0.8)
                                        )
                                        .cornerRadius(12)
                                        .foregroundColor(.primary)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // Custom Location Input Toggle
                        Button(action: {
                            showCustomInput.toggle()
                        }) {
                            HStack {
                                Image(systemName: showCustomInput ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                                Text("Enter Custom Coordinates")
                                    .font(.subheadline)
                                    .bold()
                            }
                            .foregroundColor(.orange)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.8))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        
                        // Custom Location Input Fields
                        if showCustomInput {
                            VStack(spacing: 16) {
                                TextField("Location Name (optional)", text: $customLocationName)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.horizontal)
                                
                                HStack(spacing: 12) {
                                    TextField("Latitude", text: $customLatitude)
                                        .textFieldStyle(.roundedBorder)
                                        .keyboardType(.decimalPad)
                                    
                                    TextField("Longitude", text: $customLongitude)
                                        .textFieldStyle(.roundedBorder)
                                        .keyboardType(.decimalPad)
                                }
                                .padding(.horizontal)
                                
                                Button(action: {
                                    guard let lat = Double(customLatitude),
                                          let lon = Double(customLongitude) else {
                                        viewModel.errorMessage = "Please enter valid coordinates"
                                        return
                                    }
                                    
                                    let locationName = customLocationName.isEmpty ?
                                        "Custom Location (\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon)))" :
                                        customLocationName
                                    
                                    Task {
                                        await viewModel.fetchWildfireData(
                                            latitude: lat,
                                            longitude: lon,
                                            locationName: locationName
                                        )
                                    }
                                    
                                    // Dismiss keyboard
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }) {
                                    HStack {
                                        Image(systemName: "location.magnifyingglass")
                                        Text("Check Risk")
                                            .bold()
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.orange)
                                    .cornerRadius(12)
                                }
                                .padding(.horizontal)
                                
                                Text("Example: Latitude 37.7749, Longitude -122.4194")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.6))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }
                    }
                    
                    // Loading State
                    if viewModel.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Analyzing wildfire risk...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(20)
                        .padding()
                    }
                    
                    // Error Message
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(12)
                            .padding()
                    }
                    
                    // Risk Assessment Display
                    if let assessment = viewModel.riskAssessment {
                        VStack(spacing: 20) {
                            // Risk Level Card
                            VStack(spacing: 16) {
                                Image(systemName: assessment.riskLevel.icon)
                                    .font(.system(size: 50))
                                    .foregroundColor(assessment.riskLevel.color)
                                
                                Text("Risk Level: \(assessment.riskLevel.rawValue)")
                                    .font(.title2).bold()
                                    .foregroundColor(assessment.riskLevel.color)
                                
                                if let distance = assessment.nearestFireDistance {
                                    Text("Nearest Fire: \(String(format: "%.1f", distance)) miles")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                }
                                
                                Text("\(assessment.activeFiresNearby) active fire(s) within 100 miles")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(24)
                            .background(Color.white.opacity(0.95))
                            .cornerRadius(20)
                            .shadow(radius: 5)
                            .padding(.horizontal)
                            
                            // Recommendations
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Recommendations")
                                    .font(.title3).bold()
                                    .padding(.horizontal)
                                
                                ForEach(assessment.recommendations, id: \.self) { recommendation in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.orange)
                                        Text(recommendation)
                                            .font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.9))
                                    .cornerRadius(12)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Info Footer
                    if viewModel.riskAssessment != nil {
                        VStack(spacing: 8) {
                            Text("Data from NASA FIRMS")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Last updated: \(Date(), style: .time)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                }
                .padding(.vertical)
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Ask Iris View
struct AskIrisView: View {
    @StateObject private var chatSession: IrisChatSession
    @State private var userInput: String = ""
    @State private var showGeminiGlow: Bool = false
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("profile.name") private var name: String = ""
    @AppStorage("profile.phone") private var phone: String = ""
    @AppStorage("profile.emergencyContact") private var emergencyContact: String = ""
    @AppStorage("profile.emergencyContactNumber") private var emergencyContactNumber: String = ""
    @AppStorage("profile.address") private var address: String = ""
    @AppStorage("profile.medicalConditions") private var medicalConditions: String = ""
    @AppStorage("profile.pets") private var pets: String = ""
    
    init() {
        let profile = WildfireUserProfile(
            name: UserDefaults.standard.string(forKey: "profile.name") ?? "",
            phone: UserDefaults.standard.string(forKey: "profile.phone") ?? "",
            emergencyContact: UserDefaults.standard.string(forKey: "profile.emergencyContact") ?? "",
            emergencyContactNumber: UserDefaults.standard.string(forKey: "profile.emergencyContactNumber") ?? "",
            address: UserDefaults.standard.string(forKey: "profile.address") ?? "",
            medicalConditions: UserDefaults.standard.string(forKey: "profile.medicalConditions") ?? "",
            pets: UserDefaults.standard.string(forKey: "profile.pets") ?? ""
        )
        _chatSession = StateObject(wrappedValue: IrisChatSession(userProfile: profile))
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.purple.opacity(0.6),
                    Color.blue.opacity(0.5),
                    Color.cyan.opacity(0.4)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundColor(.yellow)
                            Text("Ask Iris")
                                .font(.headline)
                                .bold()
                        }
                        Text("Wildfire Preparedness AI")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        chatSession.startNewChat()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.2))
                
                // Chat messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(chatSession.messages) { message in
                                ChatBubbleView(message: message, showGeminiGlow: $showGeminiGlow)
                                    .id(message.id)
                            }
                            
                            if chatSession.isLoading {
                                HStack {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Iris is thinking...")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding()
                            }
                            
                            if let error = chatSession.errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding()
                                    .background(Color.red.opacity(0.2))
                                    .cornerRadius(10)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: chatSession.messages.count) { _ in
                        if let lastMessage = chatSession.messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Input area
                HStack(spacing: 12) {
                    TextField("Ask about wildfire preparedness...", text: $userInput, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(20)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.purple)
                            .background(Circle().fill(Color.white))
                    }
                    .disabled(chatSession.isLoading || userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.2))
            }
        }
        .navigationBarHidden(true)
    }
    
    private func sendMessage() {
        let messageToSend = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messageToSend.isEmpty else { return }
        
        userInput = ""
        
        Task {
            await chatSession.sendUserMessage(message: messageToSend)
        }
    }
}

// MARK: - Chat Bubble View
struct ChatBubbleView: View {
    let message: ChatMessage
    @Binding var showGeminiGlow: Bool
    
    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()
            }
            
            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundColor(message.isFromUser ? .white : .black)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isFromUser ? Color.purple : Color.white)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 2)
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: message.isFromUser ? .trailing : .leading)
            
            if !message.isFromUser {
                Spacer()
            }
        }
        .padding(.horizontal)
        .transition(
            .asymmetric(
                insertion: .move(edge: message.isFromUser ? .trailing : .leading).combined(with: .opacity),
                removal: .opacity
            )
        )
    }
}

// MARK: - Find Shelter View

struct FindShelterView: View {
    @StateObject private var viewModel = ShelterViewModel()
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.red.opacity(0.3),
                    Color.orange.opacity(0.25),
                    Color.yellow.opacity(0.2)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 2) {
                        Text("Find Shelter")
                            .font(.title2.bold())
                        Text("\(viewModel.filteredShelters.count) Locations")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: { viewModel.showFilters.toggle() }) {
                        ZStack {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.title2)
                                .foregroundColor(.red)
                            
                            if !viewModel.selectedAmenities.isEmpty || !viewModel.selectedTypes.isEmpty {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 10, y: -10)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.white.opacity(0.2))
                
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("Search shelters...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                    
                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.9))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.vertical, 12)
                
                // Shelter List
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.filteredShelters) { shelter in
                            ShelterCardView(shelter: shelter, viewModel: viewModel)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $viewModel.showFilters) {
            FilterSheetView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.selectedShelter) { shelter in
            ShelterDetailView(shelter: shelter, viewModel: viewModel)
        }
    }
}

// MARK: - Shelter Card

struct ShelterCardView: View {
    let shelter: Shelter
    @ObservedObject var viewModel: ShelterViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(shelter.type.color.opacity(0.2))
                        .frame(width: 48, height: 48)
                    Image(systemName: shelter.type.icon)
                        .font(.title3)
                        .foregroundColor(shelter.type.color)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(shelter.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption)
                        Text(shelter.address)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    viewModel.selectedShelter = shelter
                }) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
            }
            
            // Capacity & Type
            HStack {
                Label(shelter.capacity, systemImage: "person.3.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                
                Text(shelter.type.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(shelter.type.color.opacity(0.1))
                    .foregroundColor(shelter.type.color)
                    .cornerRadius(8)
            }
            
            // Amenities
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelter.amenities, id: \.self) { amenity in
                        HStack(spacing: 4) {
                            Image(systemName: amenity.icon)
                                .font(.caption2)
                            Text(amenity.rawValue)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                    }
                }
            }
            
            // Action Buttons
            HStack(spacing: 12) {
                Button(action: { viewModel.callShelter(shelter.phone) }) {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text("Call")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
                }
                
                Button(action: { viewModel.openDirections(to: shelter) }) {
                    HStack {
                        Image(systemName: "map.fill")
                        Text("Directions")
                            .font(.subheadline.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                    .cornerRadius(10)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Filter Sheet

struct FilterSheetView: View {
    @ObservedObject var viewModel: ShelterViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Amenities
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Amenities")
                            .font(.headline)
                        
                        FlowLayoutView(spacing: 8) {
                            ForEach(ShelterAmenity.allCases, id: \.self) { amenity in
                                FilterChipView(
                                    icon: amenity.icon,
                                    label: amenity.rawValue,
                                    isSelected: viewModel.selectedAmenities.contains(amenity),
                                    action: { viewModel.toggleAmenity(amenity) }
                                )
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Types
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shelter Type")
                            .font(.headline)
                        
                        FlowLayoutView(spacing: 8) {
                            ForEach(ShelterType.allCases, id: \.self) { type in
                                FilterChipView(
                                    icon: type.icon,
                                    label: type.rawValue,
                                    isSelected: viewModel.selectedTypes.contains(type),
                                    color: type.color,
                                    action: { viewModel.toggleType(type) }
                                )
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { viewModel.clearFilters() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Filter Chip

struct FilterChipView: View {
    let icon: String
    let label: String
    let isSelected: Bool
    var color: Color = .blue
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color : Color.gray.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayoutView: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowLayoutResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowLayoutResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowLayoutResult {
        var size: CGSize
        var positions: [CGPoint]
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var positions: [CGPoint] = []
            var size: CGSize = .zero
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let subviewSize = subview.sizeThatFits(.unspecified)
                if currentX + subviewSize.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                positions.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, subviewSize.height)
                currentX += subviewSize.width + spacing
                size.width = max(size.width, currentX - spacing)
            }
            size.height = currentY + lineHeight
            self.size = size
            self.positions = positions
        }
    }
}

// MARK: - Shelter Detail

struct ShelterDetailView: View {
    let shelter: Shelter
    @ObservedObject var viewModel: ShelterViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ZStack {
                                Circle().fill(shelter.type.color.opacity(0.2)).frame(width: 64, height: 64)
                                Image(systemName: shelter.type.icon).font(.title).foregroundColor(shelter.type.color)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shelter.name).font(.title3.bold())
                                Text(shelter.type.rawValue).font(.subheadline).foregroundColor(shelter.type.color)
                            }
                            Spacer()
                        }
                        Divider()
                        
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Address").font(.caption).foregroundColor(.secondary)
                                Text(shelter.address).font(.body)
                            }
                        }
                        
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "phone.circle.fill").foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Phone").font(.caption).foregroundColor(.secondary)
                                Text(shelter.phone).font(.body)
                            }
                        }
                        
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "person.3.fill").foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Capacity").font(.caption).foregroundColor(.secondary)
                                Text(shelter.capacity).font(.body)
                            }
                        }
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    
                    // Amenities
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Available Services").font(.headline)
                        ForEach(shelter.amenities, id: \.self) { amenity in
                            HStack(spacing: 12) {
                                Image(systemName: amenity.icon).foregroundColor(.green).frame(width: 24)
                                Text(amenity.rawValue).font(.body)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    
                    // Notes
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Important Information").font(.headline)
                        Text(shelter.notes).font(.body).foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
                    
                    // Actions
                    VStack(spacing: 12) {
                        Button(action: { viewModel.callShelter(shelter.phone) }) {
                            HStack {
                                Image(systemName: "phone.fill")
                                Text("Call Shelter").font(.headline)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                        }
                        Button(action: { viewModel.openDirections(to: shelter) }) {
                            HStack {
                                Image(systemName: "map.fill")
                                Text("Get Directions").font(.headline)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .cornerRadius(12)
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shelter Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}


// MARK: - Evacuation Status Card Component
struct EvacuationStatusCard: View {
    @ObservedObject var locationManager: LocationManager
    @ObservedObject var statusViewModel: EvacuationStatusViewModel
    @ObservedObject var riskViewModel: WildfireRiskViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
                // Location Permission Required
                VStack(spacing: 12) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    Text("Location Access Needed")
                        .font(.headline.bold())
                    
                    Text("Enable location services to see evacuation status")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Open Settings")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .cornerRadius(10)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.98), Color.white.opacity(0.9)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .cornerRadius(28)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
                
            } else if statusViewModel.isLoading || riskViewModel.isLoading {
                // Loading State
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Checking evacuation status...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.98), Color.white.opacity(0.9)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .cornerRadius(28)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
                
            } else {
                // Status Display
                VStack(spacing: 16) {
                    HStack {
                        Text("Evacuation Status")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                        Spacer()
                    }
                    
                    // Status Icon & Title
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(statusViewModel.evacuationStatus.color.opacity(0.2))
                                .frame(width: 64, height: 64)
                            Image(systemName: statusViewModel.evacuationStatus.icon)
                                .font(.system(size: 36))
                                .foregroundColor(statusViewModel.evacuationStatus.color)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusViewModel.evacuationStatus.title)
                                .font(.title2.bold())
                                .foregroundColor(statusViewModel.evacuationStatus.color)
                            Text(statusViewModel.evacuationStatus.message)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Fire Info (if applicable)
                    if let distance = statusViewModel.nearestFireDistance {
                        Divider()
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Nearest Fire")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(String(format: "%.1f", distance)) miles")
                                    .font(.headline)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Active Fires")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(statusViewModel.activeFiresNearby)")
                                    .font(.headline)
                            }
                        }
                    }
                    
                    // Quick Actions
                    if statusViewModel.evacuationStatus == .warning || statusViewModel.evacuationStatus == .evacuateNow {
                        HStack(spacing: 12) {
                            Button(action: {
                                // Navigate to Risk Assessment (optional - can leave empty for now)
                            }) {
                                HStack {
                                    Image(systemName: "map.fill")
                                    Text("View Map")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Color.orange)
                                .cornerRadius(10)
                            }
                            
                            Button(action: {
                                // Call 911
                                if let url = URL(string: "tel://911") {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "phone.fill")
                                    Text("Call 911")
                                        .font(.subheadline.bold())
                                }
                                .foregroundColor(.white)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Color.red)
                                .cornerRadius(10)
                            }
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.98), Color.white.opacity(0.9)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
                .cornerRadius(28)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)
            }
        }
        .onAppear {
            locationManager.requestLocation()
        }
        .onChange(of: locationManager.userLocation?.latitude ?? 0) { _ in
            if let location = locationManager.userLocation {
                fetchEvacuationStatus(for: location)
            }
        }
        .onChange(of: riskViewModel.riskAssessment?.riskLevel) { _ in
            let assessment = riskViewModel.riskAssessment
            if let assessment, let location = locationManager.userLocation {
                statusViewModel.updateStatus(
                    userLat: location.latitude,
                    userLon: location.longitude,
                    riskAssessment: assessment
                )
            }
        }
    }
    
    private func fetchEvacuationStatus(for coordinate: CLLocationCoordinate2D) {
        statusViewModel.isLoading = true
        Task {
            await riskViewModel.fetchWildfireData(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                locationName: "Your Location"
            )
            await MainActor.run {
                statusViewModel.isLoading = false
            }
        }
    }
}

