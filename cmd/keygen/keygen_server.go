package main

import (
	"flag"
	"fmt"
	"net/http"

	"github.com/FlorinBalint/shortener/pkg/gcputil"
	"github.com/FlorinBalint/shortener/pkg/kubeflake"
)

var (
	listenAddr   = flag.String("address", ":8083", "HTTP listen address")
	bitsMachine  = flag.Int("bits.machine", 10, "Number of bits for machine ID")
	bitsSequence = flag.Int("bits.sequence", 16, "Number of bits for sequence ID")
	bitsCluster  = flag.Int("bits.cluster", 7, "Number of bits for cluster ID")
)

type keygenHandler struct {
	kubeFlake *kubeflake.Kubeflake
}

func newHandler() (keygenHandler, error) {
	statefulSetPod := gcputil.NewStatefulSetPod()
	settings := kubeflake.Settings{
		BitsCluster:  *bitsCluster,
		BitsMachine:  *bitsMachine,
		BitsSequence: *bitsSequence,
		ClusterId:    statefulSetPod.ClusterID,
		MachineId:    statefulSetPod.PodID,
	}

	kubeFlake, err := kubeflake.New(settings)
	if err != nil {
		return keygenHandler{}, fmt.Errorf("failed to create Kubeflake: %w", err)
	}

	return keygenHandler{
		kubeFlake: kubeFlake,
	}, nil
}

func (h *keygenHandler) generateKey(w http.ResponseWriter, r *http.Request) {
	key, err := h.kubeFlake.NextKey()
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to generate key: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, err = w.Write([]byte(key))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
}

func (h *keygenHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/health":
		w.WriteHeader(http.StatusOK)
	case "/generate/v1":
		h.generateKey(w, r)
	default:
		http.NotFound(w, r)
	}
}

func main() {
	handler, err := newHandler()
	if err != nil {
		fmt.Println("Error creating handler:", err)
		return
	}

	http.Handle("/", &handler)
	if err := http.ListenAndServe(*listenAddr, nil); err != nil {
		panic(err)
	}
}
