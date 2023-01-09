/*
See LICENSE folder for this sample’s licensing information.

Abstract:
A data object that tracks the number of drinks that the user has drunk.
*/

import SwiftUI
import Combine
import ClockKit
import HealthKit
import os

// The CoffeeData class provides a shared object that saves and loads the app's
// data.
class CoffeeData: ObservableObject {
    
    private enum HealthkitSetupError: Error {
        case notAvailableOnDevice
        case dataTypeNotAvailable
    }
    
    // A function for requesting authorization to HealthKit Parameters:
    // .heartRate
    // .activeEnergyBurned
    // .dietaryCaffeine
    // .activitySummaryType()
    
    
    let logger = Logger(subsystem: "com.example.apple-samplecode.Coffee-Tracker.watchkitapp.watchkitextension.CoffeeData", category: "Model")
    let healthStore = HKHealthStore()

    // The data model needs to be accessed both from the app extension and from
    // the complication controller.
    static let shared = CoffeeData()
    
    // The number formatter limits numbers to three significant digits.
    lazy var numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumSignificantDigits = 3
        formatter.minimumSignificantDigits = 1
        return formatter
    }()
    
    
    
    
    
    // The model uses the background queue to asynchronously save and load data.
    private var background = DispatchQueue(label: "Background Queue",
    qos: .userInitiated)
    
    // The model saves the list of drinks consumed within the last 24 hours.
    // Because this is @Published property, Combine notifies any observers when
    // a change occurs.
    @Published public var currentDrinks = [Drink]() {
        didSet {
            logger.debug("A value has been assigned to the current drinks property.")
            
            // Update any complications on active watch faces.
            let server = CLKComplicationServer.sharedInstance()
            for complication in server.activeComplications ?? [] {
                server.reloadTimeline(for: complication)
            }
            
            // Begin saving the data.
            self.save()
        }
    }
    
    
    
    
    
    // Use this value to determine whether you have changes that can be saved to disk.
    private var savedValue = [Drink]()
    
    // The currentMGCaffeine property contains the current level of caffeine in milligrams.
    // This property is calculated based on the currentDrinks array.
    public var currentMGCaffeine: Double {
        mgCaffeine(atDate: Date())
    }
    
    
    
    
    // The currentMGCaffeineString contains a user-readable string that represents the
    // current amount of caffeine in the user's body.
    public var currentMGCaffeineString: String {
        
        guard let result = numberFormatter.string(from: NSNumber(value: currentMGCaffeine)) else {
            fatalError("*** Unable to create a string for \(currentMGCaffeine) ***")
        }
        
        return result
    }

    
    
    
    
    // Calculate the amount of caffeine in the user's system at the specified date.
    // The amount of caffeine is calculated from the currentDrinks array.
    public func mgCaffeine(atDate date: Date) -> Double {
        
        var total = 0.0
        
        for drink in currentDrinks {
            total += drink.caffeineRemaining(at: date)
        }
        
        return total
    }
    
    
    
    
    
    // Return a user-readable string that describes the amount of caffeine in the user's
    // system at the specified date.
    public func mgCaffeineString(atDate date: Date) -> String {
        guard let result = numberFormatter.string(from: NSNumber(value: mgCaffeine(atDate: date))) else {
            fatalError("*** Unable to create a string for \(currentMGCaffeine) ***")
        }
        
        return result
    }
    
    
    
    
    // Return the total number of drinks consumed today. The value is in the equivalent
    // number of 8-ounce cups of coffee.
    public var totalCupsToday: Double {
        
        // Calculate midnight this morning.
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date())
        
        // Filter the drinks.
        let drinks = currentDrinks.filter { midnight.compare($0.date) == .orderedAscending }
        
        // Get the total caffeine dose.
        let totalMG = drinks.reduce(0.0) { $0 + $1.mgCaffeine }
        
        // Convert mg caffeine to equivalent cups.
        return totalMG / DrinkType.smallCoffee.mgCaffeinePerServing
    }
    
    
    
    // Return the total equivalent cups of coffee as a user-readable string.
    public var totalCupsTodayString: String {
        guard let result = numberFormatter.string(from: NSNumber(value: totalCupsToday )) else {
            fatalError("*** Unable to create a string for \(totalCupsToday) ***")
        }
        
        return result
    }
    
    // Return green, yellow, or red depending on the caffeine dose.
    public func color(forCaffeineDose dose: Double) -> UIColor {
        if dose < 200.0 {
            return .green
        } else if dose < 400.0 {
            return .yellow
        } else {
            return .red
        }
    }
    
    // Return green, yellow, or red depending on the total daily cups of coffee.
    public func color(forTotalCups cups: Double) -> UIColor {
        if cups < 3.0 {
            return .green
        } else if cups < 5.0 {
            return .yellow
        } else {
            return .red
        }
    }
    
    
    
    // Add a drink to the list of drinks.
    public func addDrink(mgCaffeine: Double, onDate date: Date) {
        logger.debug("Adding a drink.")
        
        // Create a local array to hold the changes.
        var drinks = currentDrinks
        
        // Create a new drink and add it to the array.
        let drink = Drink(mgCaffeine: mgCaffeine, onDate: date)
        drinks.append(drink)
        
        // Filter the array to get rid of any drinks that are 24 hours old.
        drinks = filterDrinks(drinks: drinks)
        
        // Update the current drinks property.
        currentDrinks = drinks
    }
    
    
    
    
    // MARK: - Private Methods
    
    // Don't call the model's initializer. Use the shared instance instead.
    private init() {
        
        // Begin loading the data from disk.
        load()
    }
    
    
    
    
    
    func getCaffeineFromHealthKit (){
        print("Getting Caffeine From HealthKit")
        guard let dietaryCaffeineType = HKObjectType.quantityType(forIdentifier: .dietaryCaffeine) else {
            fatalError("*** Unable to get the caffeine type ***")
        }
        
        var anchor = HKQueryAnchor.init(fromValue: 0)
        
        if UserDefaults.standard.object(forKey: "dietaryCaffeine") != nil {
            let data = UserDefaults.standard.object(forKey: "dietaryCaffeine") as! Data
            anchor = NSKeyedUnarchiver.unarchiveObject(with: data) as! HKQueryAnchor
        }
        
        let query = HKAnchoredObjectQuery(type: dietaryCaffeineType,
                                          predicate: nil,
                                          anchor: anchor,
                                          limit: HKObjectQueryNoLimit) { (query, samplesOrNil, deletedObjectsOrNil, newAnchor, errorOrNil) in
            guard let samples = samplesOrNil, let deletedObjects = deletedObjectsOrNil else {
                fatalError("*** An error occurred during the initial query: \(errorOrNil!.localizedDescription) ***")
                    }
                                            anchor = newAnchor!
            
                                            let data : Data = try! NSKeyedArchiver.archivedData(withRootObject: newAnchor as Any, requiringSecureCoding: true)
                                            UserDefaults.standard.set(data, forKey: "dietaryCaffeine")
            
                                            for dietaryCaffeineSample in samples {
                                                print("Caffeine Samples: \(dietaryCaffeineSample)")
                                            }
            
                                            for deletedDietaryCaffeine in deletedObjects {
                                                print("deleted: \(deletedDietaryCaffeine)")
                                            }
                                            
                                            print("Caffeine QUERY RESULTS")
                                            print("Caffeine Anchor for Anchored Healthkit Query: \(anchor)")
                                            print("Caffeine Data: \(data)")
                                            print("Caffeine samples: \(samples)")
                                            
                                            print("Caffeine on watch Today")
                                            print(self.currentMGCaffeine);
                                            
        }
        query.updateHandler = { (query, samplesOrNil, deletedObjectsOrNil, newAnchor, errorOrNil) in

            guard let samples = samplesOrNil, let deletedObjects = deletedObjectsOrNil else {
                // Handle the error here.
                fatalError("*** An error occurred during an update: \(errorOrNil!.localizedDescription) ***")
            }
            anchor = newAnchor!
            let data : Data = try! NSKeyedArchiver.archivedData(withRootObject: newAnchor as Any, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: "dietaryCaffeine")
            
            for dietaryCaffeineSample in samples {
                print("samples: \(dietaryCaffeineSample)")
            }
            
            for deletedDietaryCaffeineSample in deletedObjects {
                print("deleted: \(deletedDietaryCaffeineSample)")
            }
            
            print("Caffeine Query updateHandler")
            print(data);
            print(samples);
        }
        self.healthStore.execute(query)
    }
    
    
    
    
    
    
    func saveCaffeineInHealthKit (){
        print("Saving Caffeine To HealthKit")
        // The quantity type to write to the health store.
        let writeDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryCaffeine)!]
        // The quantity types to read from the health store.
        let readDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.stepCount)!,
                                               HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.biologicalSex)!,
                                               HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.dateOfBirth)!,
                                               HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bodyMass)!,
                                               HKObjectType.activitySummaryType()]
        
        // Request authorization for those quantity types.
        self.healthStore.requestAuthorization(toShare: writeDataTypes, read: readDataTypes) { (success, error) in
            if !success {
                // Handle the error here.
                print("Couldn't save")
            } else {
                // Once Authorized, query dietaryCaffeine
                print("Saving Caffine Data")
            }
        }
        
        if HKHealthStore.isHealthDataAvailable() {
            if let type = HKSampleType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryCaffeine) {
                let date = Date()
                print("-3 Exponent")
                
                
                let latest = Double(currentDrinks.last!.mgCaffeine)
                let mgToGrams = Double(truncating: (pow(10,-3) * latest) as NSNumber)
                
                print("Save DATA")
                print("\(latest) mg of Caffeine is \(mgToGrams) grams")
                print("Saving \(mgToGrams) grams to HealthKit")
                
                let quantity = HKQuantity(unit: HKUnit.gram(), doubleValue: mgToGrams)
                let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
                self.healthStore.save(sample, withCompletion: { (success, error) in
                    print("Saved \(success), error \(String(describing: error))")
                    if(!success){
                        print("Error Saving to Health Kit")
                    }
                })
                
                
                
                
            }
        }
    }
    
    
    
    func saveWaterInHealthKit (){
        print("Saving Water To HealthKit")
        // The quantity type to write to the health store.
        let writeDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryWater)!]
        // The quantity types to read from the health store.
        let readDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryWater)!,HKObjectType.activitySummaryType()]
        
        // Request authorization for those quantity types.
        self.healthStore.requestAuthorization(toShare: writeDataTypes, read: readDataTypes) { (success, error) in
            if !success {
                // Handle the error here.
                print("Couldn't save")
            } else {
                // Once Authorized, query dietaryCaffeine
                print("Saving Caffine Data")
            }
        }
        
        if HKHealthStore.isHealthDataAvailable() {
            if let type = HKSampleType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryWater) {
                let date = Date()
                
                let waterInOunces = Double(8.0)
                let lastDrink = currentDrinks.last!
                
                print("Save Water DATA")
                print("Last Drink was \(lastDrink)")
                print("\(waterInOunces) oz of Water")
                print("Saving \(waterInOunces) oz to HealthKit")
                
                let quantity = HKQuantity(unit: HKUnit.fluidOunceImperial(), doubleValue: waterInOunces)
                let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
                self.healthStore.save(sample, withCompletion: { (success, error) in
                    print("Saved \(success), error \(String(describing: error))")
                    if(!success){
                        print("Error Saving to Health Kit")
                    }
                })
            }
        }
    }
    
    
    
    
    // Begin saving the drink data to disk.
    private func save() {
        // Check for Healthkit Auth
        guard HKHealthStore.isHealthDataAvailable() else {
            // Request Authorization if not availible
            print("Requesting Health Kit Access")
            // The quantity type to write to the health store.
            let writeDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryCaffeine)!]
            // The quantity types to read from the health store.
            let readDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.stepCount)!,
                                                   HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.biologicalSex)!,
                                                   HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.dateOfBirth)!,
                                                   HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bodyMass)!,
                                                   HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryWater)!,
                                                   HKObjectType.activitySummaryType()]
            // Request authorization for those quantity types.
            self.healthStore.requestAuthorization(toShare: writeDataTypes, read: readDataTypes) { (success, error) in
                if !success {
                    // Handle the error here.
                    print("Couldn't read")
                } else {
                    // Once Authorized, query dietaryCaffeine
                    print("Access to Caffine Data Granted")
                    self.getCaffeineFromHealthKit()
                }
            }
            return
        }
        
        // Check if drinks are outdated
        if currentDrinks == savedValue {
            logger.debug("The drink list hasn't changed. No need to save.")
            return
        } else {
            
            // Check if Water by 0 Caffeine
            let latest = Double(currentDrinks.last!.mgCaffeine)
            if(latest == 0){
                // Saving Water
                print("Save Water to HealthKit")
                saveWaterInHealthKit()
            } else {
                // Saving Caffeine
                print("Save Caffeine to HealthKit")
                saveCaffeineInHealthKit()
            }
        }
        
        
        // Save as a binary plist file.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        
        let data: Data
        
        do {
            // Encode the currentDrinks array.
            data = try encoder.encode(currentDrinks)
        } catch {
            logger.error("An error occurred while encoding the data: \(error.localizedDescription)")
            return
        }
        
        // Save the data to disk as a binary plist file.
        let saveAction = { [unowned self] in
            do {
                
                // Write the data to disk.
                try data.write(to: self.getDataURL(), options: [.atomic])
                
                // Update the saved value.
                self.savedValue = currentDrinks
                
                self.logger.debug("Saved!")
            } catch {
                self.logger.error("An error occurred while saving the data: \(error.localizedDescription)")
            }
        }
        
        // If the app is running in the background, save synchronously.
        if WKApplication.shared().applicationState == .background {
            logger.debug("Synchronously saving the model on \(Thread.current).")
            saveAction()
        } else {
            // Otherwise save the data on a background queue.
            background.async { [unowned self] in
                logger.debug("Asynchronously saving the model on a background thread.")
                saveAction()
            }
        }
    }
    
    
    // Begin loading the data from disk.
    private func load() {
        // Read the data from a background queue.
        background.async { [unowned self] in
        logger.debug("Loading the model.")
        
        // The quantity type to write to the health store.
        let writeDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.dietaryCaffeine)!]
        
        // The quantity types to read from the health store.
        let readDataTypes : Set = [HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.stepCount)!,
                                                   HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.biologicalSex)!,
                                                   HKObjectType.characteristicType(forIdentifier: HKCharacteristicTypeIdentifier.dateOfBirth)!,
                                                   HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.bodyMass)!,
                                                   HKObjectType.activitySummaryType()]
        
        // Request authorization for those quantity types.
        self.healthStore.requestAuthorization(toShare: writeDataTypes, read: readDataTypes) { (success, error) in
                if !success {
                    // Handle the error here.
                    print("Couldn't read")
                } else {
                    // Once Authorized, query dietaryCaffeine
                    print("Access Caffine Data Granted")
                    self.getCaffeineFromHealthKit()
                }
            }
            
        // Check if Authorization Success on Load
        guard HKHealthStore.isHealthDataAvailable() else {
            // Request Auth Error
            self.logger.debug("Error Requesting HealthKit Auth")
            return
            }
        
            
            var drinks: [Drink]
            
            do {
                // Load the drink data from a binary plist file.
                let data = try Data(contentsOf: self.getDataURL())
                
                // Decode the data.
                let decoder = PropertyListDecoder()
                drinks = try decoder.decode([Drink].self, from: data)
                logger.debug("Data loaded from disk")
            } catch CocoaError.fileReadNoSuchFile {
                logger.debug("No file found--creating an empty drink list.")
                drinks = []
            } catch {
                fatalError("*** An unexpected error occurred while loading the drink list: \(error.localizedDescription) ***")
            }
            
            // Update the entires on the main queue.
            DispatchQueue.main.async { [unowned self] in
                
                // Update the saved value.
                savedValue = drinks
                
                // Filter the drinks.
                currentDrinks = filterDrinks(drinks: drinks)
                
            }
        }
    }
    
    // Returns the URL for the plist file that stores the drink data.
    private func getDataURL() throws -> URL {
        // Get the URL for the app's document directory.
        let fileManager = FileManager.default
        let documentDirectory = try fileManager.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: false)
        
        // Append the file name to the directory.
        return documentDirectory.appendingPathComponent("CoffeeTracker.plist")
    }
}

// Filter array to only the drinks in the last 24 hours.
private func filterDrinks(drinks: [Drink]) -> [Drink] {
    // The endDate property contains the current date and time.
    let endDate = Date()
    
    // The startDate property contains the date and time 24 hours ago.
    let startDate = endDate.addingTimeInterval(-24.0 * 60.0 * 60.0)
    
    // Return an array of drinks with a date parameter between
    // the start and end dates.
    return drinks.filter { (drink) -> Bool in
        (startDate.compare(drink.date) != .orderedDescending) &&
            (endDate.compare(drink.date) != .orderedAscending)
    }
}
