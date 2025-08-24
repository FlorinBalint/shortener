package gcputil

import (
	"sort"
)

// Regions maps GCP region name -> increasing integer (stable order).
// Zones maps GCP zone name -> increasing integer (stable order).
// Indices are assigned deterministically. Zones listed in topRegionZones
// are guaranteed to take the first indices, in sorted(topRegionZones) order.
var (
	Regions = map[string]int{}
	Zones   = map[string]int{}
)

// topRegionZones lists the top zones for each region.
// They will take the first IDs to ensure a global presence
// even when only 3 bits are used to encode the cluster IDs.
var topRegionZones = map[string][]string{
	"africa-south1":        {"a"}, // Johannesburg
	"asia-east1":           {"a"}, // Taiwan
	"australia-southeast2": {"a"}, // Melbourne
	"us-west1":             {"a"}, // Oregon
	"us-central1":          {"c"}, // Iowa
	"europe-west2":         {"a"}, // London
	"europe-north1":        {"a"}, // Finland
	"southamerica-east1":   {"a"}, // São Paulo
}

// TODO: Create a script that generates this map
// The script should use `gcloud compute zones list` underneath

// baseRegionZones contains the baked-in regions -> zone letters.
var baseRegionZones = map[string][]string{
	// Africa
	"africa-south1": {"a", "b", "c"},

	// Asia
	"asia-east1":      {"a", "b", "c"},
	"asia-east2":      {"a", "b", "c"},
	"asia-northeast1": {"a", "b", "c"},
	"asia-northeast2": {"a", "b", "c"},
	"asia-northeast3": {"a", "b", "c"},
	"asia-south1":     {"a", "b", "c"},
	"asia-south2":     {"a", "b", "c"},
	"asia-southeast1": {"a", "b", "c"},
	"asia-southeast2": {"a", "b", "c"},
	"asia-southeast3": {"a", "b", "c"}, // Jakarta
	"asia-southeast5": {"a", "b"},      // Malaysia

	// Australia
	"australia-southeast1": {"a", "b", "c"}, // Sydney
	"australia-southeast2": {"a", "b", "c"}, // Melbourne

	// Europe
	"europe-central2":   {"a", "b", "c"}, // Warsaw
	"europe-north1":     {"a", "b", "c"}, // Finland
	"europe-southwest1": {"a", "b", "c"}, // Madrid
	"europe-west1":      {"b", "c", "d"}, // Belgium
	"europe-west2":      {"a", "b", "c"}, // London
	"europe-west3":      {"a", "b", "c"}, // Frankfurt
	"europe-west4":      {"a", "b", "c"}, // Netherlands
	"europe-west6":      {"a", "b", "c"}, // Zurich
	"europe-west8":      {"a", "b"},      // Milan
	"europe-west9":      {"a", "b", "c"}, // Paris
	"europe-west10":     {"a", "b", "c"}, // Berlin (newer)
	"europe-west12":     {"a", "b", "c"}, // Turin

	// Middle East
	"me-central1": {"a", "b", "c"}, // Doha
	"me-central2": {"a", "b", "c"}, // Dammam
	"me-west1":    {"a", "b", "c"}, // Tel Aviv

	// North America
	"northamerica-northeast1": {"a", "b", "c"}, // Montreal
	"northamerica-northeast2": {"a", "b", "c"}, // Toronto

	// South America
	"southamerica-east1": {"a", "b", "c"}, // São Paulo
	"southamerica-west1": {"a", "b", "c"}, // Santiago

	// United States
	"us-central1": {"a", "b", "c", "f"}, // Iowa
	"us-east1":    {"b", "c", "d"},      // South Carolina
	"us-east4":    {"a", "b", "c"},      // N. Virginia
	"us-east5":    {"a", "b", "c"},      // Columbus
	"us-south1":   {"a", "b", "c"},      // Dallas
	"us-west1":    {"a", "b", "c"},      // Oregon
	"us-west2":    {"a", "b", "c"},      // Los Angeles
	"us-west3":    {"a", "b", "c"},      // Salt Lake City
	"us-west4":    {"a", "b", "c"},      // Las Vegas
}

// init builds the index maps using the current data.
func init() {
	rebuildIndices()
}

// RegionIndex returns the index for a region and whether it exists.
func RegionIndex(region string) (int, bool) {
	i, ok := Regions[region]
	return i, ok
}

// ZoneIndex returns the index for a zone and whether it exists.
func ZoneIndex(zone string) (int, bool) {
	i, ok := Zones[zone]
	return i, ok
}

// rebuildIndices rebuilds Regions and Zones ensuring topRegionZones come first.
func rebuildIndices() {
	Regions = map[string]int{}
	Zones = map[string]int{}

	// Collect regions
	allRegions := make([]string, 0, len(baseRegionZones))
	for r := range baseRegionZones {
		allRegions = append(allRegions, r)
	}
	sort.Strings(allRegions)

	// Top regions (that exist in the dataset), sorted
	topRegions := make([]string, 0, len(topRegionZones))
	for r := range topRegionZones {
		if _, ok := baseRegionZones[r]; ok {
			topRegions = append(topRegions, r)
		}
	}
	sort.Strings(topRegions)

	// Regions: top first, then the rest
	topSet := make(map[string]struct{}, len(topRegions))
	for _, r := range topRegions {
		topSet[r] = struct{}{}
	}
	restRegions := make([]string, 0, len(allRegions))
	for _, r := range allRegions {
		if _, ok := topSet[r]; !ok {
			restRegions = append(restRegions, r)
		}
	}

	rIdx := 0
	for _, r := range topRegions {
		Regions[r] = rIdx
		rIdx++
	}
	for _, r := range restRegions {
		Regions[r] = rIdx
		rIdx++
	}

	// Zones: topRegionZones first (only if present), then remaining zones by region asc, letter asc.
	zIdx := 0
	added := make(map[string]struct{}, 128)

	for _, r := range topRegions {
		letters := append([]string(nil), topRegionZones[r]...)
		sort.Strings(letters)
		for _, l := range letters {
			// Add only if this zone exists in baseRegionZones
			if !hasLetter(baseRegionZones[r], l) {
				continue
			}
			zone := r + "-" + l
			if _, ok := added[zone]; ok {
				continue
			}
			Zones[zone] = zIdx
			added[zone] = struct{}{}
			zIdx++
		}
	}

	for _, r := range allRegions {
		letters := append([]string(nil), baseRegionZones[r]...)
		sort.Strings(letters)
		for _, l := range letters {
			zone := r + "-" + l
			if _, ok := added[zone]; ok {
				continue
			}
			Zones[zone] = zIdx
			added[zone] = struct{}{}
			zIdx++
		}
	}
}

func hasLetter(letters []string, want string) bool {
	for _, l := range letters {
		if l == want {
			return true
		}
	}
	return false
}
