package kubeflake

import (
	"errors"
	"sort"
	"sync"
	"testing"
	"time"
)

func validSettings() Settings {
	return Settings{
		BitsSequence: defaultBitsSequence,
		BitsCluster:  defaultBitsCluster,
		BitsMachine:  defaultBitsMachine,
		TimeUnit:     time.Millisecond,
		EpochTime:    time.Now().Add(-24 * time.Hour),
		ClusterId: func() (int, error) {
			return 2, nil
		},
		MachineId: func() (int, error) {
			return 5, nil
		},
		Base: Base62Encoder{},
	}
}

type stepClock struct {
	mu   sync.Mutex
	now  time.Time
	step time.Duration
}

func newStepClock(start time.Time, step time.Duration) *stepClock {
	return &stepClock{now: start, step: step}
}
func (c *stepClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(c.step)
	return c.now
}

func TestNew_ValidationErrors(t *testing.T) {
	errDummy := errors.New("provider error")
	now := time.Now()

	tests := []struct {
		name    string
		mutate  func(s Settings) Settings
		wantErr error
	}{
		{
			name: "bits sequence too low",
			mutate: func(s Settings) Settings {
				s.BitsSequence = minSequenceBits - 1
				return s
			},
			wantErr: ErrInvalidBitsSequence,
		},
		{
			name: "bits sequence too high",
			mutate: func(s Settings) Settings {
				s.BitsSequence = maxSequenceBits + 1
				return s
			},
			wantErr: ErrInvalidBitsSequence,
		},
		{
			name: "bits machine too low",
			mutate: func(s Settings) Settings {
				s.BitsMachine = minMachineBits - 1
				return s
			},
			wantErr: ErrInvalidBitsMachineID,
		},
		{
			name: "bits machine too high",
			mutate: func(s Settings) Settings {
				s.BitsMachine = maxMachineBits + 1
				return s
			},
			wantErr: ErrInvalidBitsMachineID,
		},
		{
			name: "bits cluster too low",
			mutate: func(s Settings) Settings {
				s.BitsCluster = minClusterBits - 1
				return s
			},
			wantErr: ErrInvalidBitsClusterID,
		},
		{
			name: "bits cluster too high",
			mutate: func(s Settings) Settings {
				s.BitsCluster = maxClusterBits + 1
				return s
			},
			wantErr: ErrInvalidBitsClusterID,
		},
		{
			name: "time unit negative",
			mutate: func(s Settings) Settings {
				s.TimeUnit = -time.Millisecond
				return s
			},
			wantErr: ErrInvalidTimeUnit,
		},
		{
			name: "time unit too small positive",
			mutate: func(s Settings) Settings {
				s.TimeUnit = 100 * time.Microsecond
				return s
			},
			wantErr: ErrInvalidTimeUnit,
		},
		{
			name: "epoch time ahead of now",
			mutate: func(s Settings) Settings {
				s.EpochTime = now.Add(1 * time.Hour)
				return s
			},
			wantErr: ErrStartTimeAhead,
		},
		{
			name: "time bits too small (overflow at construction)",
			mutate: func(s Settings) Settings {
				// Force bitsTime = 64 - (30 + 16 + 8) = 10 < 32
				s.BitsSequence = 30
				s.BitsMachine = 16
				s.BitsCluster = 8
				return s
			},
			wantErr: ErrInvalidBitsTime,
		},
		{
			name: "cluster id provider error",
			mutate: func(s Settings) Settings {
				s.ClusterId = func() (int, error) { return 0, errDummy }
				return s
			},
			wantErr: errDummy,
		},
		{
			name: "machine id provider error",
			mutate: func(s Settings) Settings {
				s.MachineId = func() (int, error) { return 0, errDummy }
				return s
			},
			wantErr: errDummy,
		},
	}

	for _, tt := range tests {
		s := validSettings()
		if tt.mutate != nil {
			s = tt.mutate(s)
		}
		_, err := New(s)
		if tt.wantErr == nil && err != nil {
			t.Fatalf("%s: unexpected error: %v", tt.name, err)
		}
		if tt.wantErr != nil {
			if err == nil {
				t.Fatalf("%s: expected error %v, got nil", tt.name, tt.wantErr)
			}
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("%s: expected error %v, got %v", tt.name, tt.wantErr, err)
			}
		}
	}
}

func TestNew_ProviderValuesAreStored(t *testing.T) {
	s := validSettings()
	wantCluster := 3
	wantMachine := 7
	s.ClusterId = func() (int, error) { return wantCluster, nil }
	s.MachineId = func() (int, error) { return wantMachine, nil }

	kf, err := New(s)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if kf.clusterId != wantCluster {
		t.Fatalf("clusterId: want %d, got %d", wantCluster, kf.clusterId)
	}
	if kf.machineId != wantMachine {
		t.Fatalf("machineId: want %d, got %d", wantMachine, kf.machineId)
	}
}

func TestNextID_MonotonicSequential(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}
	// Deterministic time progression to avoid sleeps
	clk := newStepClock(s.EpochTime.Add(10*time.Second), time.Millisecond)
	kf.nowFunc = clk.Now

	const n = 2000
	var last uint64
	for i := 0; i < n; i++ {
		id, err := kf.NextID()
		if err != nil {
			t.Fatalf("NextID error: %v", err)
		}
		if i > 0 && id <= last {
			t.Fatalf("ids must increase: last=%d current=%d at i=%d", last, id, i)
		}
		last = id
	}
}

func TestNextID_MonotonicParallel(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}
	clk := newStepClock(s.EpochTime.Add(5*time.Second), time.Millisecond)
	kf.nowFunc = clk.Now

	const goroutines = 8
	const perG = 500
	ids := make([]uint64, 0, goroutines*perG)
	var mu sync.Mutex
	var wg sync.WaitGroup

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			local := make([]uint64, 0, perG)
			for i := 0; i < perG; i++ {
				id, err := kf.NextID()
				if err != nil {
					t.Errorf("NextID error: %v", err)
					return
				}
				local = append(local, id)
			}
			mu.Lock()
			ids = append(ids, local...)
			mu.Unlock()
		}()
	}
	wg.Wait()

	if len(ids) != goroutines*perG {
		t.Fatalf("expected %d ids, got %d", goroutines*perG, len(ids))
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for i := 1; i < len(ids); i++ {
		if ids[i] <= ids[i-1] {
			t.Fatalf("ids must be strictly increasing at %d: %d <= %d", i, ids[i], ids[i-1])
		}
	}
}

func TestNextKey_MonotonicAndDecodable(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}
	clk := newStepClock(s.EpochTime.Add(7*time.Second), time.Millisecond)
	kf.nowFunc = clk.Now

	const n = 500
	var last uint64
	for i := 0; i < n; i++ {
		key, err := kf.NextKey()
		if err != nil {
			t.Fatalf("NextKey error: %v", err)
		}
		id, err := kf.encoder.Decode(key)
		if err != nil {
			t.Fatalf("Decode error: %v", err)
		}
		if i > 0 && id <= last {
			t.Fatalf("ids must increase via keys: last=%d current=%d at i=%d", last, id, i)
		}
		last = id
	}
}

func TestComposeDecompose_RoundTrip(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}

	tm := s.EpochTime.Add(42 * time.Millisecond)
	seq := (1 << s.BitsSequence) - 3
	cl := (1 << s.BitsCluster) - 2
	mc := (1 << s.BitsMachine) - 5

	id, err := kf.Compose(tm, seq, mc, cl)
	if err != nil {
		t.Fatalf("Compose error: %v", err)
	}
	parts := kf.Decompose(id)

	// Validate parts
	elapsed := kf.toInternalTime(tm.UTC()) - kf.startTime
	if parts[Timestamp] != elapsed {
		t.Fatalf("timestamp mismatch: want %d, got %d", elapsed, parts[Timestamp])
	}
	if parts[Sequence] != uint64(seq) {
		t.Fatalf("sequence mismatch: want %d, got %d", seq, parts[Sequence])
	}
	if parts[MachineID] != uint64(mc) {
		t.Fatalf("machine mismatch: want %d, got %d", mc, parts[MachineID])
	}
	if parts[ClusterID] != uint64(cl) {
		t.Fatalf("cluster mismatch: want %d, got %d", cl, parts[ClusterID])
	}
}

func TestComposeKeyDecomposeKey_RoundTrip(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}

	tm := s.EpochTime.Add(123 * time.Millisecond)
	seq := 7
	cl := 3
	mc := 11

	key, err := kf.ComposeKey(tm, seq, mc, cl)
	if err != nil {
		t.Fatalf("ComposeKey error: %v", err)
	}

	parts, err := kf.DecomposeKey(key)
	if err != nil {
		t.Fatalf("DecomposeKey error: %v", err)
	}

	elapsed := kf.toInternalTime(tm.UTC()) - kf.startTime
	if parts[Timestamp] != elapsed {
		t.Fatalf("timestamp mismatch: want %d, got %d", elapsed, parts[Timestamp])
	}
	if parts[Sequence] != uint64(seq) {
		t.Fatalf("sequence mismatch: want %d, got %d", seq, parts[Sequence])
	}
	if parts[MachineID] != uint64(mc) {
		t.Fatalf("machine mismatch: want %d, got %d", mc, parts[MachineID])
	}
	if parts[ClusterID] != uint64(cl) {
		t.Fatalf("cluster mismatch: want %d, got %d", cl, parts[ClusterID])
	}
}

func TestCompose_Errors(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}

	validT := s.EpochTime.Add(1 * time.Second)
	validSeq := 0
	validCl := 0
	validMc := 0

	tests := []struct {
		name    string
		tm      time.Time
		seq     int
		mc      int
		cl      int
		wantErr error
	}{
		{
			name:    "time before epoch",
			tm:      s.EpochTime.Add(-1 * time.Millisecond),
			seq:     validSeq,
			mc:      validMc,
			cl:      validCl,
			wantErr: ErrStartTimeAhead,
		},
		{
			name:    "sequence too small",
			tm:      validT,
			seq:     -1,
			mc:      validMc,
			cl:      validCl,
			wantErr: ErrInvalidSequence,
		},
		{
			name:    "sequence too large",
			tm:      validT,
			seq:     1<<s.BitsSequence + 1,
			mc:      validMc,
			cl:      validCl,
			wantErr: ErrInvalidSequence,
		},
		{
			name:    "machine too small",
			tm:      validT,
			seq:     validSeq,
			mc:      -1,
			cl:      validCl,
			wantErr: ErrInvalidMachineID,
		},
		{
			name:    "machine too large",
			tm:      validT,
			seq:     validSeq,
			mc:      1<<s.BitsMachine + 1,
			cl:      validCl,
			wantErr: ErrInvalidMachineID,
		},
		{
			name:    "cluster too small",
			tm:      validT,
			seq:     validSeq,
			mc:      validMc,
			cl:      -1,
			wantErr: ErrInvalidClusterID,
		},
		{
			name:    "cluster too large",
			tm:      validT,
			seq:     validSeq,
			mc:      validMc,
			cl:      1<<s.BitsCluster + 1,
			wantErr: ErrInvalidClusterID,
		},
		{
			name: "over time limit",
			tm: func() time.Time {
				// Use the current instance's bitsTime to compute the first invalid moment
				maxElapsed := uint64(1) << kf.bitsTime // elapsed units allowed: [0, maxElapsed-1]
				return s.EpochTime.Add(time.Duration(maxElapsed) * s.TimeUnit)
			}(),
			seq:     validSeq,
			mc:      validMc,
			cl:      validCl,
			wantErr: ErrOverTimeLimit,
		},
	}

	for _, tt := range tests {
		_, err := kf.Compose(tt.tm, tt.seq, tt.mc, tt.cl)
		if tt.wantErr == nil {
			if err != nil {
				t.Fatalf("%s: unexpected error: %v", tt.name, err)
			}
		} else {
			if err == nil || !errors.Is(err, tt.wantErr) {
				t.Fatalf("%s: expected error %v, got %v", tt.name, tt.wantErr, err)
			}
		}
	}
}

func TestDecomposeKey_InvalidBase(t *testing.T) {
	s := validSettings()
	kf, err := New(s)
	if err != nil {
		t.Fatalf("New error: %v", err)
	}
	// '!' is not in base62 alphabet
	_, err = kf.DecomposeKey("abc!def")
	if err == nil || !errors.Is(err, ErrInvalidBase) {
		t.Fatalf("expected ErrInvalidBase, got %v", err)
	}
}

func TestBase62_EncodeDecode_RoundTrip(t *testing.T) {
	b := Base62Encoder{}
	values := []uint64{
		0, 1, 61, 62, 63, 12345, 1<<32 - 1, 1<<40 + 123, 1<<63 - 1, // up to u64 across
	}
	for _, v := range values {
		s := b.Encode(v)
		got, err := b.Decode(s)
		if err != nil {
			t.Fatalf("decode(%q) error: %v", s, err)
		}
		if got != v {
			t.Fatalf("round-trip mismatch: want %d, got %d (str=%q)", v, got, s)
		}
	}
}
