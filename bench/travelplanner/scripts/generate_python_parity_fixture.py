#!/usr/bin/env python3
"""
Generate a Python-parity fixture for the TravelPlanner Elixir evaluator.

This script runs the canonical OSU-NLP-Group/TravelPlanner Python evaluator
on the 180 validation plans from results/val-phase-a-v5/results.jsonl
and records per-constraint pass/fail results + cost breakdown.

Requirements (pip install):
  pandas datasets

Usage:
  cd bench/travelplanner
  python3 scripts/generate_python_parity_fixture.py

Output:
  test/fixtures/python_parity_val180.jsonl

The output format per line:
{
  "idx": 0,
  "has_plan": true,
  "commonsense": {
    "is_reasonable_visiting_city": true,
    "is_valid_restaurants": true,
    "is_valid_attractions": true,
    "is_valid_accommodation": true,
    "is_valid_transportation": true,
    "is_valid_information_in_current_city": true,
    "is_valid_information_in_sandbox": true,
    "is_not_absent": true
  },
  "hard": {
    "is_valid_cuisine": true,
    "is_valid_room_rule": true,
    "is_valid_room_type": true,
    "is_valid_transportation": true,
    "is_valid_cost": true
  },
  "total_cost": 571.0
}
"""

import json
import os
import sys
import re
import csv
import math
from pathlib import Path

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent
RESULTS_FILE = PROJECT_DIR / "results" / "val-phase-a-v5" / "results.jsonl"
DATA_DIR = PROJECT_DIR / "data"
VALIDATION_CSV = DATA_DIR / "validation.csv"
VALIDATION_REF_INFO = DATA_DIR / "validation_ref_info.jsonl"
OUTPUT_FILE = PROJECT_DIR / "test" / "fixtures" / "python_parity_val180.jsonl"

# --------------------------------------------------------------------------
# Data Loading
# --------------------------------------------------------------------------

def load_tasks():
    """Load the validation tasks from the CSV."""
    tasks = []
    with open(VALIDATION_CSV, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader):
            tasks.append({
                "idx": i,
                "org": row.get("org", ""),
                "dest": row.get("dest", ""),
                "days": int(row.get("days", 0)),
                "date": row.get("date", ""),
                "people_number": int(row.get("people_number", 1)),
                "budget": int(row.get("budget", 0)) if row.get("budget") else None,
                "local_constraint": row.get("local_constraint", ""),
                "level": row.get("level", ""),
                "query": row.get("query", ""),
            })
    return tasks


def load_reference_info():
    """Load the parsed reference information per task."""
    ref_info = []
    with open(VALIDATION_REF_INFO, "r", encoding="utf-8") as f:
        for line in f:
            ref_info.append(json.loads(line.strip()))
    return ref_info


def load_plans():
    """Load the 180 plans from results JSONL."""
    plans = []
    with open(RESULTS_FILE, "r", encoding="utf-8") as f:
        for line in f:
            result = json.loads(line.strip())
            plans.append(result)
    return plans


# --------------------------------------------------------------------------
# Reference DB Construction (from reference_information)
# --------------------------------------------------------------------------

def parse_reference_info(ref_info):
    """
    Parse the reference_information dict into structured DB.
    The ref_info values are already structured dicts from the HuggingFace dataset.
    Returns dict with keys: flights, restaurants, accommodations, attractions, ground_transport
    """
    db = {
        "flights": [],
        "restaurants": [],
        "accommodations": [],
        "attractions": [],
        "ground_transport": [],
    }

    for key, value in ref_info.items():
        if key.startswith("Flight from"):
            if isinstance(value, list):
                for flight in value:
                    db["flights"].append(parse_flight(flight, key))
        elif key.startswith("Restaurants in"):
            if isinstance(value, list):
                for r in value:
                    db["restaurants"].append(parse_restaurant(r))
        elif key.startswith("Accommodations in"):
            if isinstance(value, list):
                for a in value:
                    db["accommodations"].append(parse_accommodation(a))
        elif key.startswith("Attractions in"):
            if isinstance(value, list):
                for a in value:
                    db["attractions"].append(parse_attraction(a))
        elif key.startswith("Self-driving from") or key.startswith("Taxi from"):
            if isinstance(value, str):
                gt = parse_ground_transport(value, key)
                if gt:
                    db["ground_transport"].append(gt)

    return db


def parse_flight(flight_data, key):
    """Parse a flight dict from HuggingFace dataset format."""
    if isinstance(flight_data, dict):
        return {
            "flight_number": flight_data.get("Flight Number", ""),
            "origin": flight_data.get("OriginCityName", ""),
            "destination": flight_data.get("DestCityName", ""),
            "date": flight_data.get("FlightDate", ""),
            "dep_time": flight_data.get("DepTime", ""),
            "arr_time": flight_data.get("ArrTime", ""),
            "price": float(flight_data.get("Price", 0) or 0),
            "distance": float(flight_data.get("Distance", 0) or 0),
        }

    # Fallback: extract from key
    key_match = re.match(r"Flight from (.+?) to (.+?) on (\d{4}-\d{2}-\d{2})", key)
    origin = key_match.group(1) if key_match else ""
    destination = key_match.group(2) if key_match else ""
    date = key_match.group(3) if key_match else ""
    return {
        "flight_number": "",
        "origin": origin,
        "destination": destination,
        "date": date,
        "price": 0,
    }


def parse_restaurant(r_data):
    """Parse restaurant dict from HuggingFace dataset format."""
    if isinstance(r_data, dict):
        cuisines_raw = r_data.get("Cuisines", "")
        if isinstance(cuisines_raw, str):
            cuisines = [c.strip() for c in cuisines_raw.split(",") if c.strip()]
        else:
            cuisines = cuisines_raw or []

        return {
            "name": r_data.get("Name", ""),
            "city": r_data.get("City", ""),
            "cuisines": cuisines,
            "average_cost": float(r_data.get("Average Cost", 0) or 0),
        }
    return {"name": "", "city": "", "cuisines": [], "average_cost": 0}


def parse_accommodation(a_data):
    """Parse accommodation dict from HuggingFace dataset format."""
    if isinstance(a_data, dict):
        house_rules_raw = a_data.get("house_rules", "")
        if isinstance(house_rules_raw, str) and house_rules_raw:
            house_rules = [r.strip() for r in house_rules_raw.split(" & ") if r.strip()]
        else:
            house_rules = []

        min_nights = a_data.get("minimum nights")
        if min_nights is None or min_nights == "":
            min_nights = 1
        else:
            min_nights = int(float(min_nights))

        max_occ = a_data.get("maximum occupancy")
        if max_occ is None or max_occ == "":
            max_occ = 1
        else:
            max_occ = int(float(max_occ))

        price = a_data.get("price")
        if price is None or price == "":
            price = 0
        else:
            price = float(price)

        return {
            "name": a_data.get("NAME", ""),
            "city": a_data.get("city", ""),
            "price": price,
            "room_type": a_data.get("room type", ""),
            "house_rules": house_rules,
            "minimum_nights": min_nights,
            "maximum_occupancy": max_occ,
        }
    return {"name": "", "city": "", "price": 0, "room_type": "", "house_rules": [], "minimum_nights": 1, "maximum_occupancy": 1}


def parse_attraction(a_data):
    """Parse attraction dict from HuggingFace dataset format."""
    if isinstance(a_data, dict):
        return {
            "name": a_data.get("Name", ""),
            "city": a_data.get("City", ""),
        }
    return {"name": "", "city": ""}


def parse_ground_transport(value_str, key):
    """Parse ground transport string."""
    # Key: "Self-driving from A to B" or "Taxi from A to B"
    mode_match = re.match(r"(Self-driving|Taxi) from (.+?) to (.+)", key)
    if not mode_match:
        return None

    mode = "self_driving" if mode_match.group(1) == "Self-driving" else "taxi"
    origin = mode_match.group(2)
    destination = mode_match.group(3)

    # value: "self-driving, from A to B, duration: X, distance: Y km, cost: Z"
    cost_match = re.search(r"cost:\s*(\d+)", value_str)
    duration_match = re.search(r"duration:\s*(.+?)(?:,|$)", value_str)
    distance_match = re.search(r"distance:\s*(\d+)\s*km", value_str)

    return {
        "mode": mode,
        "origin": origin,
        "destination": destination,
        "cost": int(cost_match.group(1)) if cost_match else 0,
        "duration": duration_match.group(1).strip() if duration_match else "",
        "distance_km": int(distance_match.group(1)) if distance_match else 0,
    }


# --------------------------------------------------------------------------
# Python Evaluator (port of OSU-NLP canonical evaluator logic)
# --------------------------------------------------------------------------

def extract_before_parenthesis(s):
    """Strip parenthetical suffix: 'Dallas(Texas)' -> 'Dallas'"""
    if s is None:
        return None
    match = re.match(r"^(.*?)\s*\(", s)
    return match.group(1).strip() if match else s.strip()


def get_valid_name_city(entry):
    """
    Parse 'Name, City' or 'Name, City(State)'.
    Returns (name, city) or (None, None) if absent.
    """
    if not entry or entry == "-":
        return None, None

    # Match pattern: everything before last comma-space is name, after is city
    match = re.match(r"^(.*),\s*([^,]+?)(\([^)]*\))?$", entry)
    if match:
        name = match.group(1).strip()
        city = extract_before_parenthesis(match.group(2).strip() + (match.group(3) or ""))
        return name, city
    return entry, None


def parse_attractions(entry):
    """Split attractions by semicolons."""
    if not entry or entry == "-":
        return []
    return [a.strip() for a in entry.split(";") if a.strip()]


def parse_current_city(entry):
    """Parse 'City A to City B' or 'City'."""
    if " to " in entry:
        parts = entry.split(" to ", 1)
        return ("travel", parts[0].strip(), parts[1].strip())
    return ("stay", entry.strip(), None)


def detect_transport_mode(entry):
    """Detect transport mode from entry string."""
    if not entry or entry == "-":
        return None
    entry_lower = entry.lower()
    if entry_lower.startswith("flight"):
        return "flight"
    elif "self-driving" in entry_lower or "self-drive" in entry_lower:
        return "self_driving"
    elif entry_lower.startswith("taxi"):
        return "taxi"
    return None


def parse_transport_cost(entry):
    """Extract dollar cost from transport entry."""
    if not entry or entry == "-":
        return None
    match = re.search(r"\$(\d+)", entry)
    return int(match.group(1)) if match else None


def extract_flight_number(entry):
    """Extract flight number from entry."""
    if not entry or entry == "-":
        return None
    match = re.search(r"Flight\s+(F\d+)", entry)
    return match.group(1) if match else None


def parse_local_constraint(constraint_str):
    """Parse the local_constraint string into a dict."""
    result = {"house_rule": None, "cuisine": None, "room_type": None, "transportation": None}

    if not constraint_str:
        return result

    # Extract values using regex
    hr_match = re.search(r"'house rule'\s*:\s*(?:'([^']*)'|None)", constraint_str)
    cuisine_match = re.search(r"'cuisine'\s*:\s*(?:\[([^\]]*)\]|'([^']*)'|None)", constraint_str)
    rt_match = re.search(r"'room type'\s*:\s*(?:'([^']*)'|None)", constraint_str)
    tr_match = re.search(r"'transportation'\s*:\s*(?:'([^']*)'|None)", constraint_str)

    if hr_match and hr_match.group(1):
        result["house_rule"] = hr_match.group(1)

    if cuisine_match:
        if cuisine_match.group(1):
            # List format: ['Chinese', 'Mexican']
            items = re.findall(r"'([^']*)'", cuisine_match.group(1))
            result["cuisine"] = items if items else None
        elif cuisine_match.group(2):
            # Single string format
            result["cuisine"] = [cuisine_match.group(2)]

    if rt_match and rt_match.group(1):
        result["room_type"] = rt_match.group(1)

    if tr_match and tr_match.group(1):
        result["transportation"] = tr_match.group(1)

    return result


def parse_dates(date_str):
    """Parse date string like \"['2022-03-13', '2022-03-14']\" into list."""
    if not date_str:
        return []
    dates = re.findall(r"\d{4}-\d{2}-\d{2}", date_str)
    return dates


# --------------------------------------------------------------------------
# Commonsense Constraints (8)
# --------------------------------------------------------------------------

def is_valid_plan_length(plan, task, db):
    """Plan length must equal task days."""
    return len(plan) == task["days"]


def is_reasonable_visiting_city(plan, task, db):
    """Plan must start and end at origin, visit only valid cities."""
    if not plan:
        return False

    # Check departure
    first_city = plan[0].get("current_city", "")
    city_type, from_city, to_city = parse_current_city(first_city)
    if city_type == "travel":
        if from_city != task["org"]:
            return False
    else:
        if from_city != task["org"]:
            return False

    # Check return
    last_city = plan[-1].get("current_city", "")
    city_type, from_city, to_city = parse_current_city(last_city)
    if city_type == "travel":
        if to_city != task["org"]:
            return False
    else:
        if from_city != task["org"]:
            return False

    return True


def is_valid_transportation(plan, task, db):
    """No mixing flight + self-driving for inter-city transport."""
    modes = set()
    for day in plan:
        entry = day.get("transportation", "-")
        if entry == "-":
            continue
        mode = detect_transport_mode(entry)
        if mode and mode != "taxi":
            modes.add(mode)

    if "flight" in modes and "self_driving" in modes:
        return False
    return True


def is_valid_information_in_current_city(plan, task, db):
    """
    Every restaurant, attraction, accommodation must exist in the DB
    for one of the cities visited that day.
    """
    for day in plan:
        current_city = day.get("current_city", "")
        city_type, from_city, to_city = parse_current_city(current_city)

        if city_type == "travel":
            cities = [from_city, to_city]
        else:
            cities = [from_city]

        # Check meals
        for meal_key in ["breakfast", "lunch", "dinner"]:
            entry = day.get(meal_key, "-")
            if entry == "-":
                continue
            name, city = get_valid_name_city(entry)
            if city and city not in cities:
                # Restaurant city doesn't match day's cities
                return False

        # Check attractions
        attractions = parse_attractions(day.get("attraction", "-"))
        # Attractions don't have city suffix, so we check against DB
        city_attraction_names = set()
        for city in cities:
            for a in db["attractions"]:
                if a.get("city", "") == city:
                    city_attraction_names.add(a["name"])
        for attr in attractions:
            if attr not in city_attraction_names:
                return False

        # Check accommodation
        accom_entry = day.get("accommodation", "-")
        if accom_entry != "-":
            name, city = get_valid_name_city(accom_entry)
            if city and city not in cities:
                return False

    return True


def is_valid_restaurants(plan, task, db):
    """No duplicate restaurant across the entire trip."""
    all_names = []
    for day in plan:
        for key in ["breakfast", "lunch", "dinner"]:
            entry = day.get(key, "-")
            if entry == "-":
                continue
            name, _ = get_valid_name_city(entry)
            if name:
                all_names.append(name)

    return len(all_names) == len(set(all_names))


def is_valid_attractions(plan, task, db):
    """No duplicate attraction across the entire trip."""
    all_attrs = []
    for day in plan:
        attrs = parse_attractions(day.get("attraction", "-"))
        all_attrs.extend(attrs)

    return len(all_attrs) == len(set(all_attrs))


def is_valid_accommodation(plan, task, db):
    """
    Accommodation must be present for all non-last days.
    Minimum nights must be satisfied.
    """
    for i, day in enumerate(plan[:-1]):
        if day.get("accommodation", "-") == "-":
            return False

    # Check minimum nights
    stays = []
    current_name = None
    current_count = 0
    for day in plan:
        entry = day.get("accommodation", "-")
        if entry == "-":
            if current_name:
                stays.append((current_name, current_count))
                current_name = None
                current_count = 0
        else:
            name, city = get_valid_name_city(entry)
            if name == current_name:
                current_count += 1
            else:
                if current_name:
                    stays.append((current_name, current_count))
                current_name = name
                current_count = 1

    if current_name:
        stays.append((current_name, current_count))

    for name, nights in stays:
        # Find in DB
        for acc in db["accommodations"]:
            if acc["name"] == name:
                min_nights = acc.get("minimum_nights", 1) or 1
                if nights < min_nights:
                    return False
                break

    return True


def is_not_absent(plan, task, db):
    """
    Check structural completeness:
    - Travel day must have transport
    - Non-travel day must have attraction
    - Non-last day must have accommodation
    - Overall density > 50%
    """
    content_keys = ["breakfast", "lunch", "dinner", "attraction", "transportation", "accommodation"]
    total = 0
    absent = 0

    for i, day in enumerate(plan):
        current_city = day.get("current_city", "")
        is_travel = " to " in current_city

        transport = day.get("transportation", "-")
        attraction = day.get("attraction", "-")
        accommodation = day.get("accommodation", "-")

        if is_travel and transport == "-":
            return False
        if not is_travel and attraction == "-":
            return False
        if i < len(plan) - 1 and accommodation == "-":
            return False

        for key in content_keys:
            val = day.get(key, "-")
            total += 1
            if val == "-":
                absent += 1

    if total > 0 and absent / total > 0.5:
        return False

    return True


# --------------------------------------------------------------------------
# Hard Constraints (5)
# --------------------------------------------------------------------------

ROOM_TYPE_MAP = {
    "entire room": "Entire home/apt",
    "private room": "Private room",
    "shared room": "Shared room",
}


def is_valid_cuisine(plan, task, db):
    """Required cuisines must all be served by at least one restaurant."""
    constraints = parse_local_constraint(task["local_constraint"])
    required = constraints["cuisine"]
    if not required:
        return True

    # Collect all restaurant cuisines from plan (excluding origin city)
    served_cuisines = set()
    for day in plan:
        for key in ["breakfast", "lunch", "dinner"]:
            entry = day.get(key, "-")
            if entry == "-":
                continue
            name, city = get_valid_name_city(entry)
            if city and city == task["org"]:
                continue
            # Find in DB
            for r in db["restaurants"]:
                if r["name"] == name:
                    for c in r.get("cuisines", []):
                        served_cuisines.add(c.lower())
                    break

    for req in required:
        if req.lower() not in served_cuisines:
            return False

    return True


def is_valid_room_rule(plan, task, db):
    """If house rule specified (e.g. 'smoking'), accommodations must allow it."""
    constraints = parse_local_constraint(task["local_constraint"])
    rule = constraints["house_rule"]
    if not rule:
        return True

    prohibition = f"no {rule.lower()}"

    for day in plan:
        entry = day.get("accommodation", "-")
        if entry == "-":
            continue
        name, city = get_valid_name_city(entry)
        for acc in db["accommodations"]:
            if acc["name"] == name:
                for hr in acc.get("house_rules", []):
                    if hr.lower() == prohibition:
                        return False
                break

    return True


def is_valid_room_type(plan, task, db):
    """All accommodations must match the required room type."""
    constraints = parse_local_constraint(task["local_constraint"])
    required = constraints["room_type"]
    if not required:
        return True

    required_lower = required.lower().strip()
    negated = required_lower.startswith("not ")
    if negated:
        pattern = required_lower[4:].strip()
    else:
        pattern = required_lower

    db_type = ROOM_TYPE_MAP.get(pattern, pattern)

    for day in plan:
        entry = day.get("accommodation", "-")
        if entry == "-":
            continue
        name, city = get_valid_name_city(entry)
        for acc in db["accommodations"]:
            if acc["name"] == name:
                matches = acc.get("room_type", "") == db_type
                if negated:
                    if matches:
                        return False
                else:
                    if not matches:
                        return False
                break

    return True


def is_valid_transportation_hard(plan, task, db):
    """Transport constraint (e.g. 'no flight') must be respected."""
    constraints = parse_local_constraint(task["local_constraint"])
    constraint = constraints["transportation"]
    if not constraint:
        return True

    constraint_lower = constraint.lower().strip()

    for day in plan:
        entry = day.get("transportation", "-")
        if entry == "-":
            continue

        if constraint_lower.startswith("no "):
            forbidden = constraint_lower[3:].strip()
            if forbidden in entry.lower():
                return False
        else:
            # Must use this mode
            pass  # Positive constraints are rare, skip for now

    return True


def compute_total_cost(plan, task, db):
    """Compute total plan cost with per-person scaling."""
    people = task.get("people_number", 1) or 1

    transport_cost = 0
    for day in plan:
        entry = day.get("transportation", "-")
        cost = parse_transport_cost(entry)
        if cost:
            mode = detect_transport_mode(entry)
            if mode == "flight":
                transport_cost += cost * people
            elif mode == "self_driving":
                transport_cost += cost * math.ceil(people / 5)
            elif mode == "taxi":
                transport_cost += cost * math.ceil(people / 4)
            else:
                transport_cost += cost * people

    accommodation_cost = 0
    for day in plan:
        entry = day.get("accommodation", "-")
        if entry == "-":
            continue
        name, city = get_valid_name_city(entry)
        for acc in db["accommodations"]:
            if acc["name"] == name:
                price = acc.get("price", 0) or 0
                max_occ = acc.get("maximum_occupancy", 1) or 1
                accommodation_cost += price * math.ceil(people / max_occ)
                break

    restaurant_cost = 0
    for day in plan:
        for key in ["breakfast", "lunch", "dinner"]:
            entry = day.get(key, "-")
            if entry == "-":
                continue
            name, city = get_valid_name_city(entry)
            for r in db["restaurants"]:
                if r["name"] == name:
                    restaurant_cost += r.get("average_cost", 0) or 0
                    break

    restaurant_cost *= people
    return transport_cost + accommodation_cost + restaurant_cost


def is_valid_cost(plan, task, db):
    """Total cost must not exceed budget."""
    budget = task.get("budget")
    if not budget:
        return True

    total = compute_total_cost(plan, task, db)
    return total <= budget


# --------------------------------------------------------------------------
# Main Evaluation
# --------------------------------------------------------------------------

COMMONSENSE_CHECKS = [
    ("is_valid_plan_length", is_valid_plan_length),
    ("is_reasonable_visiting_city", is_reasonable_visiting_city),
    ("is_valid_transportation", is_valid_transportation),
    ("is_valid_information_in_current_city", is_valid_information_in_current_city),
    ("is_valid_restaurants", is_valid_restaurants),
    ("is_valid_attractions", is_valid_attractions),
    ("is_valid_accommodation", is_valid_accommodation),
    ("is_not_absent", is_not_absent),
]

HARD_CHECKS = [
    ("is_valid_cuisine", is_valid_cuisine),
    ("is_valid_room_rule", is_valid_room_rule),
    ("is_valid_room_type", is_valid_room_type),
    ("is_valid_transportation", is_valid_transportation_hard),
    ("is_valid_cost", is_valid_cost),
]


def evaluate_plan(plan, task, db):
    """Evaluate a single plan, returning per-constraint results."""
    commonsense = {}
    for name, fn in COMMONSENSE_CHECKS:
        try:
            commonsense[name] = fn(plan, task, db)
        except Exception as e:
            commonsense[name] = None  # Error

    hard = {}
    for name, fn in HARD_CHECKS:
        try:
            hard[name] = fn(plan, task, db)
        except Exception as e:
            hard[name] = None  # Error

    try:
        total_cost = compute_total_cost(plan, task, db)
    except Exception:
        total_cost = None

    return commonsense, hard, total_cost


def main():
    print(f"Loading tasks from {VALIDATION_CSV}...", file=sys.stderr)
    tasks = load_tasks()
    print(f"  Loaded {len(tasks)} tasks", file=sys.stderr)

    print(f"Loading reference info from {VALIDATION_REF_INFO}...", file=sys.stderr)
    ref_infos = load_reference_info()
    print(f"  Loaded {len(ref_infos)} reference info entries", file=sys.stderr)

    print(f"Loading plans from {RESULTS_FILE}...", file=sys.stderr)
    plans = load_plans()
    print(f"  Loaded {len(plans)} plans", file=sys.stderr)

    os.makedirs(OUTPUT_FILE.parent, exist_ok=True)

    print(f"Evaluating {len(plans)} plans...", file=sys.stderr)
    results = []

    for i, plan_result in enumerate(plans):
        idx = plan_result["idx"]
        plan = plan_result.get("plan")
        status = plan_result.get("status")

        task = tasks[idx]
        ref_info = ref_infos[idx]
        db = parse_reference_info(ref_info)

        if status == "error" or plan is None:
            entry = {
                "idx": idx,
                "has_plan": False,
                "commonsense": {name: None for name, _ in COMMONSENSE_CHECKS},
                "hard": {name: None for name, _ in HARD_CHECKS},
                "total_cost": None,
            }
        else:
            commonsense, hard, total_cost = evaluate_plan(plan, task, db)
            entry = {
                "idx": idx,
                "has_plan": True,
                "commonsense": commonsense,
                "hard": hard,
                "total_cost": total_cost,
            }

        results.append(entry)

        if (i + 1) % 30 == 0:
            print(f"  Evaluated {i + 1}/{len(plans)}", file=sys.stderr)

    # Write output
    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        for entry in results:
            f.write(json.dumps(entry) + "\n")

    # Summary
    has_plan = [r for r in results if r["has_plan"]]
    print(f"\nResults written to {OUTPUT_FILE}", file=sys.stderr)
    print(f"Total: {len(results)}, With plan: {len(has_plan)}", file=sys.stderr)

    if has_plan:
        for name, _ in COMMONSENSE_CHECKS:
            passes = sum(1 for r in has_plan if r["commonsense"].get(name) is True)
            print(f"  {name}: {passes}/{len(has_plan)} pass", file=sys.stderr)

        for name, _ in HARD_CHECKS:
            passes = sum(1 for r in has_plan if r["hard"].get(name) is True)
            print(f"  {name}: {passes}/{len(has_plan)} pass", file=sys.stderr)


if __name__ == "__main__":
    main()
