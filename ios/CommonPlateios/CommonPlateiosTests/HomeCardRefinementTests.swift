import SwiftUI
import UIKit
import XCTest
@testable import CommonPlateios

@MainActor
final class HomeCardRefinementTests: XCTestCase {
    private func request(
        meals: [MealItem]? = nil,
        path: RequestMenuPath = .mealExchange,
        cents: Int? = nil,
        scheduled: Bool = false,
        status: RequestStatus = .open
    ) -> FoodRequest {
        let meals = meals ?? [MealItem(name: "Veggie Wrap", details: "DETAILS MUST STAY ON DETAIL")]
        return FoodRequest(
            id: "home-refinement",
            diningSpot: DiningSpot(name: "Crave NYU", address: nil),
            foodDescription: "FULL SUMMARY MUST STAY ON DETAIL",
            pickupWindowText: "ASAP",
            mealSwipes: path == .mealExchange ? meals.count : 0,
            resource: RequestResource(
                menuPath: path, mealItems: meals,
                orderDetails: "FREE FORM MUST STAY ON DETAIL",
                estimatedDiningDollarsCents: cents
            ),
            windowStart: scheduled ? Date().addingTimeInterval(1800) : nil,
            windowEnd: scheduled ? Date().addingTimeInterval(3600) : nil,
            createdAt: Date(), expiresAt: Date().addingTimeInterval(7200),
            status: status
        )
    }

    func testPreviewUsesTheFirstNameVerbatimAndCountsOnlyAdditionalEntries() {
        let name = "  vEgGiE Wrap; extra \n requester text  "
        for count in 1...3 {
            let meals = [MealItem(name: name, details: "never append this")]
                + Array(repeating: MealItem(name: "Other meal"), count: count - 1)
            XCTAssertEqual(
                RequestCardView.homeMealPreview(for: request(meals: meals)),
                name + (count > 1 ? " + \(count - 1) more" : "")
            )
        }
    }

    func testMissingOrUnusableFirstMealOmitsPreviewWithoutSearchingLaterMeals() {
        let cases: [[MealItem]] = [[], [MealItem(name: "")], [MealItem(name: " \n\t"), MealItem(name: "Second")]]
        for meals in cases {
            XCTAssertNil(RequestCardView.homeMealPreview(for: request(meals: meals)))
        }
    }

    func testDiningDollarsNeverInventsAPreviewEvenWithMalformedMealEntries() {
        let dollars = request(path: .diningDollars, cents: 1450)
        XCTAssertNil(RequestCardView.homeMealPreview(for: dollars))
        XCTAssertEqual(RequestCardView.homeResourceText(for: dollars), "$14.50 Dining Dollars")
    }

    func testResourceAmountsAreFieldBasedAndMixedRequestsKeepTheEstimate() {
        let mixed = request(meals: ["First", "Second", "Third"], cents: 250)
        XCTAssertEqual(RequestCardView.homeResourceText(for: mixed), "3 meal swipes + $2.50 Dining Dollars")
        XCTAssertEqual(RequestCardView.homeResourceText(for: request()), "1 meal swipe")
        XCTAssertEqual(RequestCardView.homeResourceText(for: request(cents: 0)), "1 meal swipe + $0.00 Dining Dollars")
        XCTAssertEqual(mixed.foodDescription, "FULL SUMMARY MUST STAY ON DETAIL")
        XCTAssertEqual(mixed.resource.estimatedDiningDollarsCents, 250)
    }

    func testSingleMixedResourceHomeCardWrapsNaturallyAndKeepsItsStatus() throws {
        let meals = [MealItem(name: "Sesame tofu bowl", details: "not shown on Home")]
        let mixed = request(meals: meals, cents: 2500)
        let singleResource = request(meals: meals)
        XCTAssertEqual(
            RequestCardView.homeResourceText(for: mixed),
            "1 meal swipe + $25.00 Dining Dollars"
        )
        XCTAssertEqual(RequestCardView.homeMealPreview(for: mixed), "Sesame tofu bowl")

        func renderedHeight(_ request: FoodRequest, size: DynamicTypeSize) -> CGFloat {
            UIHostingController(rootView:
                RequestCardView(
                    request: request,
                    kind: .own,
                    showsOwnershipEyebrow: false,
                    ownerPhase: .reserved,
                    isHomePresentation: true
                )
                .dynamicTypeSize(size)
            )
            .sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            .height
        }

        for (size, appearance) in [
            (DynamicTypeSize.large, ColorScheme.light),
            (.accessibility3, .dark)
        ] {
            let (window, elements) = try host(
                RequestCardView(
                    request: mixed,
                    kind: .own,
                    showsOwnershipEyebrow: false,
                    ownerPhase: .reserved,
                    isHomePresentation: true
                ),
                size: size,
                appearance: appearance
            )
            defer { window.isHidden = true }
            let card = try XCTUnwrap(elements.first {
                $0.accessibilityLabel?.contains("1 meal swipe + $25.00 Dining Dollars") == true
            })
            let label = try XCTUnwrap(card.accessibilityLabel)
            for required in ["1 meal swipe + $25.00 Dining Dollars", "Being helped", "Crave NYU", "Sesame tofu bowl"] {
                XCTAssertTrue(label.contains(required), "missing \(required) in \(label)")
            }
            XCTAssertFalse(label.contains("not shown on Home"))
            XCTAssertGreaterThan(card.accessibilityFrame.height, 0)
            XCTAssertGreaterThan(renderedHeight(mixed, size: size), renderedHeight(singleResource, size: size))

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Home single mixed-resource card \(size) \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testExactFiveMinuteWarningBoundaryAndMinuteAlignedRefresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (seconds, urgent) in [(301.0, false), (300.001, false), (300, true), (299.999, true), (1, true)] {
            XCTAssertEqual(
                RequestCardView.isHelpingTimeUrgent(until: now.addingTimeInterval(seconds), now: now),
                urgent, "\(seconds) seconds"
            )
        }
        let deadline = now.addingTimeInterval(437)
        let start = RequestCardView.minuteAlignedStart(for: deadline, now: now)
        let warningInstant = deadline.addingTimeInterval(-300)
        XCTAssertEqual(warningInstant.timeIntervalSince(start).truncatingRemainder(dividingBy: 60), 0)
        XCTAssertEqual(RequestCardView.remainingTimeText(until: deadline, now: warningInstant), "5 min left")
    }

    func testHomeHelpingClockAndTimeSelectTheNeutralOrWarningTokenAtTheBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func resolved(_ color: Color, _ style: UIUserInterfaceStyle = .light) -> UIColor {
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        }
        XCTAssertEqual(
            resolved(RequestCardView.homeHelpingTimeColor(until: now.addingTimeInterval(301), now: now)),
            resolved(RequestCardView.beingHelpedColor)
        )
        XCTAssertEqual(
            resolved(RequestCardView.homeHelpingTimeColor(until: now.addingTimeInterval(300.001), now: now)),
            resolved(RequestCardView.beingHelpedColor)
        )
        XCTAssertEqual(
            resolved(RequestCardView.homeHelpingTimeColor(until: now.addingTimeInterval(300), now: now)),
            resolved(CommonPlateStyle.Color.homeUrgentStatus)
        )
        XCTAssertEqual(
            resolved(RequestCardView.homeHelpingTimeColor(until: now.addingTimeInterval(299), now: now), .dark),
            resolved(CommonPlateStyle.Color.homeUrgentStatus, .dark)
        )
        XCTAssertEqual(
            resolved(RequestCardView.homeHelpingTimeColor(until: now.addingTimeInterval(301), now: now), .dark),
            resolved(RequestCardView.beingHelpedColor, .dark)
        )
    }

    func testHomeStatusesUseNeutralWarningAndSharedUrgentAccents() throws {
        func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        }
        let source = try appSource("Views/RequestCardView.swift")
        XCTAssertTrue(source.contains(
            "ownerStatusPill(Self.beingHelpedLabel, color: Self.beingHelpedColor)"
        ), "Being helped retains the shared amber warning role")
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertTrue(source.contains(
                "ownerStatusPill(Self.availableToHelpersLabel, color: CommonPlateStyle.Color.timing)"
            ))
            XCTAssertEqual(
                resolved(RequestCardView.beingHelpedColor, style),
                resolved(RequestCardView.homeHelpingTimeColor(
                    until: Date(timeIntervalSince1970: 2_000_301),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                "Being helped and a non-urgent helping timer share amber"
            )
            XCTAssertEqual(
                resolved(RequestCardView.homeHelpingTimeColor(
                    until: Date(timeIntervalSince1970: 2_000_301),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                resolved(RequestCardView.beingHelpedColor, style),
                "More than five minutes uses the amber warning"
            )
            XCTAssertEqual(
                resolved(RequestCardView.homeHelpingTimeColor(
                    until: Date(timeIntervalSince1970: 2_000_300),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                resolved(CommonPlateStyle.Color.homeUrgentStatus, style),
                "Five minutes or less shares Confirm pickup's urgent red"
            )
            XCTAssertEqual(
                resolved(RequestCardView.homePickupAttentionColor, style),
                resolved(CommonPlateStyle.Color.homeUrgentStatus, style)
            )
            XCTAssertEqual(
                resolved(RequestCardView.homeHelpingCardSurface(
                    until: Date(timeIntervalSince1970: 2_000_301),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                resolved(CommonPlateStyle.Color.helpingCardSurface, style),
                "More than five minutes keeps the normal helping surface"
            )
            XCTAssertEqual(
                resolved(RequestCardView.homeHelpingCardSurface(
                    until: Date(timeIntervalSince1970: 2_000_300),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                resolved(CommonPlateStyle.Color.homeUrgentCardSurface, style),
                "Five minutes or less shares Confirm pickup's urgent surface"
            )
            XCTAssertEqual(
                resolved(RequestCardView.homeHelpingCardBorder(
                    until: Date(timeIntervalSince1970: 2_000_300),
                    now: Date(timeIntervalSince1970: 2_000_000)
                ), style),
                resolved(CommonPlateStyle.Color.homeUrgentCardBorder, style),
                "Urgent helping uses the shared Confirm pickup border"
            )
        }
    }

    func testRequesterStatusUsesTheAuthoritativePhaseAndCampusScheduledTime() {
        let calendar = NYUCampusTime.calendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 17))!
        let todayAtSix = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 18))!
        let tomorrowAtSix = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18))!
        func plain(_ value: String) -> String { value.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(RequestCardView.homeScheduledStatus(start: todayAtSix, now: now)), "Scheduled for 6:00 PM")
        XCTAssertEqual(
            plain(RequestCardView.homeScheduledStatus(start: tomorrowAtSix, now: now)),
            "Scheduled for Oct 24 · 6:00 PM"
        )
        XCTAssertEqual(
            plain(RequestCardView.homeScheduledStatus(start: todayAtSix, now: todayAtSix.addingTimeInterval(3600))),
            "Scheduled for Oct 23 · 6:00 PM",
            "when the date has passed, retain it instead of saying Today or implying available"
        )
        let iso = ISO8601DateFormatter()
        let justBeforeCampusMidnight = iso.date(from: "2026-10-24T02:30:00Z")!
        XCTAssertEqual(
            plain(RequestCardView.homeScheduledStatus(
                start: iso.date(from: "2026-10-24T03:00:00Z")!,
                now: justBeforeCampusMidnight
            )),
            "Scheduled for 11:00 PM",
            "calendar-day and display-time use the NYU timezone, not UTC"
        )
        XCTAssertEqual(
            plain(RequestCardView.homeScheduledStatus(
                start: iso.date(from: "2026-10-24T04:30:00Z")!,
                now: justBeforeCampusMidnight
            )),
            "Scheduled for Oct 24 · 12:30 AM",
            "the status disambiguates a start after NYU campus midnight"
        )
    }

    func testHostedCardsKeepSemanticOrderAndExcludeFullInstructionsAndTimingTypes() throws {
        for kind in [
            RequestCardKind.open, .own,
            .helping(claimExpiresAt: Date().addingTimeInterval(780)),
            .helping(claimExpiresAt: Date().addingTimeInterval(299))
        ] {
            for (size, appearance) in [(DynamicTypeSize.large, ColorScheme.light), (.accessibility3, .dark)] {
                let r = request(meals: [
                    MealItem(name: String(repeating: "Exact requester-authored wrap ", count: 12), details: "SECRET DETAILS"),
                    MealItem(name: "Second")
                ], scheduled: true)
                let card = RequestCardView(
                    request: r, kind: kind, showsOwnershipEyebrow: false,
                    ownerPhase: kind == .own ? .reserved : nil,
                    isHomePresentation: true
                )
                let (window, elements) = try host(card, size: size, appearance: appearance)
                defer { window.isHidden = true }
                let labels = elements.compactMap(\.accessibilityLabel).joined(separator: "\n")
                let resourceRange = try XCTUnwrap(labels.range(of: "2 meal swipes"))
                let restaurantRange = try XCTUnwrap(labels.range(of: "Crave NYU"))
                XCTAssertLessThan(resourceRange.lowerBound, restaurantRange.lowerBound)
                for absent in ["SECRET DETAILS", "FULL SUMMARY", "FREE FORM", "ASAP", "Today", "Continue →"] {
                    XCTAssertFalse(labels.contains(absent), absent)
                }
                if case .helping(let deadline) = kind {
                    XCTAssertTrue(labels.contains(RequestCardView.remainingTimeText(until: deadline)))
                    XCTAssertFalse(labels.contains("Exact requester-authored wrap"))
                } else {
                    XCTAssertTrue(labels.contains("Exact requester-authored wrap"))
                    XCTAssertTrue(labels.contains("+ 1 more"))
                }
                if kind == .own {
                    let statusRange = try XCTUnwrap(labels.range(of: "Being helped"))
                    XCTAssertLessThan(resourceRange.lowerBound, statusRange.lowerBound)
                    XCTAssertLessThan(statusRange.lowerBound, restaurantRange.lowerBound)
                }
                let cardElement = try XCTUnwrap(elements.first { $0.accessibilityLabel?.contains("2 meal swipes") == true })
                XCTAssertGreaterThan(cardElement.accessibilityFrame.height, 0)
                XCTAssertGreaterThanOrEqual(cardElement.accessibilityFrame.minX, -1)
                XCTAssertLessThanOrEqual(cardElement.accessibilityFrame.maxX, window.bounds.width + 1)
                if case .helping = kind, size.isAccessibilitySize {
                    XCTAssertLessThan(cardElement.accessibilityFrame.height, 320, "the primary resource must not be squeezed into a narrow column")
                }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Home card \(kind) \(size) \(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testLongPreviewRemainsOneVisualLineAndDoesNotMutateTheRequest() {
        let short = request(meals: ["Wrap"])
        let long = request(meals: [MealItem(name: String(repeating: "Requester text ", count: 100))])
        for size in [DynamicTypeSize.large, .accessibility3] {
            func height(_ r: FoodRequest) -> CGFloat {
                let controller = UIHostingController(rootView:
                    RequestCardView(request: r, kind: .open, isHomePresentation: true)
                        .dynamicTypeSize(size)
                )
                return controller.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)).height
            }
            XCTAssertEqual(height(short), height(long), accuracy: 1)
        }
        XCTAssertEqual(long.resource.mealItems[0].name, String(repeating: "Requester text ", count: 100))
    }

    func testOwnStatusesAndDiningDollarsRenderWithoutInventedFood() throws {
        for phase in [OwnerRequestPhase.available, .reserved, .scheduled] {
            let r = request(meals: [], path: .diningDollars, cents: 1450, scheduled: phase == .scheduled)
            let (window, elements) = try host(RequestCardView(
                request: r,
                kind: .own, showsOwnershipEyebrow: false, ownerPhase: phase, isHomePresentation: true
            ))
            defer { window.isHidden = true }
            let labels = elements.compactMap(\.accessibilityLabel).joined(separator: "\n")
            XCTAssertTrue(labels.contains("$14.50 Dining Dollars"))
            XCTAssertTrue(labels.contains("Crave NYU"))
            XCTAssertFalse(labels.contains("FREE FORM"))
            XCTAssertFalse(labels.contains("meal swipe"))
            XCTAssertEqual(labels.contains("Available to helpers"), phase == .available)
            XCTAssertEqual(labels.contains("Being helped"), phase == .reserved)
            if phase == .scheduled {
                XCTAssertTrue(labels.contains(RequestCardView.homeScheduledStatus(start: r.windowStart!)))
                XCTAssertFalse(labels.contains("ASAP"))
                XCTAssertFalse(labels.contains("Later"))
            } else if phase == .available {
                XCTAssertTrue(labels.contains("Available to helpers"))
                XCTAssertFalse(labels.contains("Scheduled for"))
            } else {
                XCTAssertTrue(labels.contains("Being helped"))
                XCTAssertFalse(labels.contains("Available to helpers"))
            }
        }
    }

    func testHomeHelpingCardHasNoChevronAndRetainsWarningTreatment() throws {
        let source = try appSource("Views/RequestCardView.swift")
        let start = try XCTUnwrap(source.range(of: "private var homeContent:"))
        let end = try XCTUnwrap(source.range(of: "private var isWaitingForPickup:"))
        let home = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(source.contains(#"Image(systemName: "chevron.right")"#))
        XCTAssertFalse(home.contains("RequestMealView"))
        XCTAssertFalse(home.contains("continueLabel"))
        XCTAssertTrue(home.contains(".lineLimit(1)"))
        XCTAssertTrue(source.contains("Self.homeHelpingTimeColor(until: claimExpiresAt, now: context.date)"))
        XCTAssertTrue(source.contains("CommonPlateStyle.Color.homeUrgentStatus"))
        let links = try appSource("Views/HelperContinuationsListView.swift")
        XCTAssertTrue(links.contains("AppRoute.fulfillment(claim.request)"))
        XCTAssertTrue(links.contains("claimExpiresAt: claim.claimExpiresAt"))
        XCTAssertTrue(links.contains(#".accessibilityHint("Open your helping reservation")"#))
        let continuity = try appSource("Views/RequestCreationContinuityView.swift")
        XCTAssertTrue(continuity.contains("ownerPhase: ownerPhase"))
        XCTAssertTrue(continuity.contains("isHomePresentation: true"))
        let helperLinks = try appSource("Views/HelperContinuationsListView.swift")
        XCTAssertTrue(helperLinks.contains("HelperContinuationCardButtonStyle()"))
        XCTAssertTrue(helperLinks.contains(".scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)"))
        let root = try appSource("ContentView.swift")
        XCTAssertTrue(root.contains("ownerPhase: requestStore.ownerRequests.first { $0.id == continuity.request.id }?.phase"))
    }

    func testConfirmPickupHomeColorsMeetTextContrastInBothAppearances() throws {
        func contrast(_ foreground: UIColor, _ background: UIColor, dark: Bool) -> Double {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            func luminance(_ color: UIColor) -> Double {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                func linear(_ component: CGFloat) -> Double {
                    let value = Double(component)
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            }
            let first = luminance(foreground), second = luminance(background)
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }

        for dark in [false, true] {
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            let foreground = UIColor(RequestCardView.homePickupAttentionColor)
            let surface = UIColor(CommonPlateStyle.Color.homeUrgentCardSurface)
            XCTAssertGreaterThanOrEqual(contrast(foreground, surface, dark: dark), 4.5, "dark=\(dark)")
            XCTAssertGreaterThanOrEqual(
                contrast(
                    UIColor(RequestCardView.beingHelpedColor),
                    UIColor(CommonPlateStyle.Color.helpingCardSurface),
                    dark: dark
                ),
                4.5,
                "warning contrast dark=\(dark)"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(
                    UIColor(CommonPlateStyle.Color.homeUrgentStatus),
                    UIColor(CommonPlateStyle.Color.helpingCardSurface),
                    dark: dark
                ),
                4.5,
                "urgent timer contrast dark=\(dark)"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(
                    UIColor(CommonPlateStyle.Color.homeUrgentStatus),
                    UIColor(CommonPlateStyle.Color.homeUrgentCardSurface),
                    dark: dark
                ),
                4.5,
                "urgent helping card contrast dark=\(dark)"
            )
            XCTAssertEqual(
                foreground.resolvedColor(with: traits),
                UIColor(CommonPlateStyle.Color.homeUrgentStatus)
                    .resolvedColor(with: traits)
            )
        }
        let source = try appSource("Views/RequestCardView.swift")
        XCTAssertTrue(source.contains("isHomePresentation ? Self.homePickupAttentionColor : Self.pickupAttentionColor"))
        XCTAssertTrue(source.contains("CommonPlateStyle.Color.homeUrgentCardSurface"))
        XCTAssertTrue(source.contains("CommonPlateStyle.Color.homeUrgentCardBorder"))
        XCTAssertTrue(source.contains(".lineSpacing(request.resource.estimatedDiningDollarsCents == nil ? 0 : -2)"))
    }

    func testCaptureHomeStatusAndMixedResourceReviewCardsInBothAppearances() throws {
        let now = Date()
        let mixed = request(
            meals: [MealItem(name: "Sesame tofu bowl"), MealItem(name: "Seasonal greens"), MealItem(name: "Fruit cup")],
            cents: 2500
        )
        let pickup = request(status: .placed)
        let captures: [(String, RequestCardView)] = [
            (
                "Continue helping over five minutes",
                RequestCardView(
                    request: request(),
                    kind: .helping(claimExpiresAt: now.addingTimeInterval(900)),
                    isHomePresentation: true
                )
            ),
            (
                "Continue helping five minutes or less",
                RequestCardView(
                    request: request(),
                    kind: .helping(claimExpiresAt: now.addingTimeInterval(240)),
                    isHomePresentation: true
                )
            ),
            (
                "Confirm pickup",
                RequestCardView(
                    request: pickup,
                    kind: .own,
                    showsOwnershipEyebrow: false,
                    placedOrderNeedsPickupConfirmation: true,
                    isHomePresentation: true
                )
            ),
            (
                "Mixed-resource Needs help",
                RequestCardView(request: mixed, kind: .open, isHomePresentation: true)
            )
        ]

        for appearance in [ColorScheme.light, .dark] {
            for (label, card) in captures {
                let (window, _) = try host(card, appearance: appearance)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Fixture-backed \(appearance) Home \(label)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
    }

    func testHelpingIndicatorUsesANeutralDotThenARedClockTightlyBeforeTheTime() throws {
        let source = try appSource("Views/RequestCardView.swift")
        let start = try XCTUnwrap(source.range(of: "case (.helping(let claimExpiresAt), _):"))
        let end = try XCTUnwrap(source.range(of: "default:", range: start.upperBound..<source.endIndex))
        let helping = String(source[start.lowerBound..<end.lowerBound])
        let urgent = try XCTUnwrap(helping.range(of: "if Self.isHelpingTimeUrgent(until: claimExpiresAt, now: context.date)"))
        let clock = try XCTUnwrap(helping.range(of: #"Image(systemName: "clock")"#))
        let dot = try XCTUnwrap(helping.range(of: "Circle()"))
        let time = try XCTUnwrap(helping.range(of: "Text(Self.remainingTimeText(until: claimExpiresAt, now: context.date))"))
        XCTAssertLessThan(urgent.lowerBound, clock.lowerBound)
        XCTAssertLessThan(clock.lowerBound, dot.lowerBound, "the clock is the urgent branch, the dot the neutral one")
        XCTAssertLessThan(dot.lowerBound, time.lowerBound, "indicator precedes the time")
        XCTAssertTrue(helping.contains(".frame(width: 8, height: 8)"), "same dot size as owner statuses")
        XCTAssertTrue(helping.contains("HStack(spacing: Self.homeHelpingIndicatorSpacing)"))
        XCTAssertFalse(helping.contains("Label {"), "no loosely spaced Label icon")
        XCTAssertLessThanOrEqual(RequestCardView.homeHelpingIndicatorSpacing, 6)
        // The dot and text share the neutral token above 300 s; the clock and
        // text share the warning token at or below it.
        let now = Date()
        XCTAssertFalse(RequestCardView.isHelpingTimeUrgent(until: now.addingTimeInterval(301), now: now))
        XCTAssertTrue(RequestCardView.isHelpingTimeUrgent(until: now.addingTimeInterval(300), now: now))
    }

    func testOwnedHomeStatusUsesTheTrailingHeaderAndScheduledUsesTheSharedDot() throws {
        let source = try appSource("Views/RequestCardView.swift")
        let start = try XCTUnwrap(source.range(of: "private var homeContent:"))
        let end = try XCTUnwrap(source.range(of: "private var homeResourceTitle:"))
        let header = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(header.contains("if hasHomeTrailingStatus"))
        XCTAssertTrue(header.contains("return kind == .own"))
        XCTAssertTrue(header.contains(".frame(maxWidth: .infinity, alignment: .trailing)"))
        XCTAssertTrue(header.contains("Spacer(minLength: CommonPlateStyle.Spacing.s)\n                    ownerOrTimingLabel"))
        XCTAssertFalse(header.contains("if kind == .own || isWaitingForPickup"))
        // Faith: Waiting for pickup shares the same trailing corner slot.
        XCTAssertTrue(header.contains("return kind == .own || isWaitingForPickup"))
        XCTAssertFalse(header.contains("if isWaitingForPickup {"))
        XCTAssertTrue(source.contains(
            "ownerStatusPill(Self.homeScheduledStatus(start: start), color: CommonPlateStyle.Color.timing)"
        ))
        XCTAssertTrue(source.contains("Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)"))
    }

    func testWholeCardRemainsAnAccessibleNavigationControl() throws {
        let r = request()
        for kind in [RequestCardKind.open, .own, .helping(claimExpiresAt: Date().addingTimeInterval(780))] {
            let route: AppRoute
            switch kind {
            case .helping: route = .fulfillment(r)
            case .own: route = .ownerRequest(.provisional(from: r))
            case .open: route = .requestDetail(r)
            case .waitingForPickup: XCTFail("Home owner/helping test does not cover waiting-for-pickup")
                continue
            }
            let (window, elements) = try host(NavigationStack {
                NavigationLink(value: route) {
                    RequestCardView(request: r, kind: kind, showsOwnershipEyebrow: false, isHomePresentation: true)
                }
                .buttonStyle(.plain)
                .navigationDestination(for: AppRoute.self) { _ in Text("Destination") }
            })
            defer { window.isHidden = true }
            let control = try XCTUnwrap(elements.first {
                $0.accessibilityLabel?.contains("1 meal swipe") == true
                    && $0.accessibilityTraits.contains(.button)
            })
            XCTAssertGreaterThanOrEqual(control.accessibilityFrame.height, 44)
            XCTAssertGreaterThan(control.accessibilityFrame.width, 250)
        }
    }

    private func host<V: View>(
        _ view: V, size: DynamicTypeSize = .large, appearance: ColorScheme = .light
    ) throws -> (UIWindow, [NSObject]) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            view.padding(.horizontal, CommonPlateStyle.Metrics.homeContentColumnInset)
                .dynamicTypeSize(size).environment(\.colorScheme, appearance)
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        var seen = Set<ObjectIdentifier>()
        var elements: [NSObject] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            elements.append(object)
            for child in object.accessibilityElements ?? [] {
                if let child = child as? NSObject { visit(child) }
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
            }
            if let view = object as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(window)
        return (window, elements)
    }

    private func appSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CommonPlateios")
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
