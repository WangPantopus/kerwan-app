// whisper-bridging-header.h
// WhisperService — Objective-C / C bridging header
//
// Exposes the whisper.cpp C API to Swift.
//
// Build-setting requirement
// ─────────────────────────
// In the WhisperService target's Build Settings set:
//   SWIFT_OBJC_BRIDGING_HEADER = WhisperService/whisper-bridging-header.h
//
// whisper.cpp source integration
// ───────────────────────────────
// Add whisper.cpp and ggml to the WhisperService target as compiled sources,
// or link against a pre-built libwhisper.a / whisper.xcframework.
// The header below must match the whisper.cpp version in use.
// Tested against whisper.cpp commit v1.7.x (ggml-large-v3-turbo compatible).
//
// Only the symbols used by WhisperTranscriptionEngine.swift are declared here;
// for the full API see whisper.h in the whisper.cpp repository.

#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque context handle
// ---------------------------------------------------------------------------

struct whisper_context;
struct whisper_state;

typedef int32_t whisper_token;
typedef int64_t whisper_pos;

// ---------------------------------------------------------------------------
// whisper_context_params — passed to whisper_init_from_file_with_params
// ---------------------------------------------------------------------------

struct whisper_context_params {
    bool use_gpu;          // Use Metal / CUDA GPU acceleration
    bool flash_attn;       // Use Flash Attention (Metal only, reduces VRAM)
    int  gpu_device;       // CUDA device index (ignored on Metal)
    bool dtw_token_timestamps; // Dynamic Time Warping for word-level timestamps
};

WHISPER_API struct whisper_context_params whisper_context_default_params(void);

// ---------------------------------------------------------------------------
// Sampling strategy
// ---------------------------------------------------------------------------

enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY      = 0,
    WHISPER_SAMPLING_BEAM_SEARCH = 1,
};

// ---------------------------------------------------------------------------
// Callbacks (declared here so whisper_full_params compiles; unused in Kerwan)
// ---------------------------------------------------------------------------

typedef void (*whisper_new_segment_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef bool (*whisper_progress_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef bool (*whisper_encoder_begin_callback)(struct whisper_context *, struct whisper_state *, void *);
typedef bool (*whisper_logits_filter_callback)(struct whisper_context *, struct whisper_state *, const whisper_token *, int, float *, void *);
typedef bool (*whisper_abort_callback)(void *);

// ---------------------------------------------------------------------------
// whisper_full_params
// ---------------------------------------------------------------------------

struct whisper_full_params {
    enum whisper_sampling_strategy strategy;

    int n_threads;          // Number of CPU threads (default: 4)
    int n_max_text_ctx;     // Max tokens in text context  (default: 16384)
    int offset_ms;          // Audio offset in milliseconds (default: 0)
    int duration_ms;        // Audio duration to process, 0 = all (default: 0)

    bool translate;         // Translate to English (default: false)
    bool no_context;        // Do not use past transcription as context (default: true)
    bool no_timestamps;     // Do not generate timestamps (default: false)
    bool single_segment;    // Force a single segment output (default: false)
    bool print_special;     // Print special tokens (default: false)
    bool print_progress;    // Print progress info (default: true)
    bool print_realtime;    // Print results in real-time (default: false)
    bool print_timestamps;  // Print timestamps (default: true)

    bool token_timestamps;  // Enable token-level timestamps (default: false)
    float thold_pt;         // Timestamp token probability threshold (default: 0.01)
    float thold_ptsum;      // Timestamp token sum probability threshold (default: 0.01)
    int max_len;            // Max segment length in characters, 0 = no limit
    bool split_on_word;     // Split on word boundaries (default: false)
    int max_tokens;         // Max tokens per segment, 0 = no limit (default: 0)

    bool debug_mode;        // Enable debug mode (default: false)
    int audio_ctx;          // Audio encoder context size, 0 = all (default: 0)

    bool tdrz_enable;       // tinydiarize speaker turn detection (default: false)

    // Language / task
    const char * suppress_regex; // Regex to suppress tokens (default: NULL)
    const char * initial_prompt; // Initial prompt for the decoder (default: NULL)
    const whisper_token * prompt_tokens;
    int prompt_n_tokens;

    const char * language;  // Language code, "auto" = auto-detect (default: "en")
    bool detect_language;   // Override language detection (default: false)

    bool suppress_blank;    // Suppress blank tokens at start (default: true)
    bool suppress_non_speech_tokens; // Suppress non-speech tokens (default: false)

    float temperature;      // Initial decoding temperature (default: 0.0)
    float max_initial_ts;   // Max initial timestamp (default: 1.0)
    float length_penalty;   // Length penalty (default: -1.0 = none)

    float temperature_inc;  // Temperature increment on fallback (default: 0.2)
    float entropy_thold;    // Entropy fallback threshold (default: 2.4)
    float logprob_thold;    // Avg log prob fallback threshold (default: -1.0)
    float no_speech_thold;  // No-speech token prob threshold (default: 0.6)

    struct {
        int best_of;        // Greedy: number of candidates (default: 5)
    } greedy;

    struct {
        int beam_size;      // Beam search width (default: 5)
        float patience;     // Beam search patience (default: -1.0)
    } beam_search;

    // Callbacks (set to NULL when not needed)
    whisper_new_segment_callback    new_segment_callback;
    void *                          new_segment_callback_user_data;

    whisper_progress_callback       progress_callback;
    void *                          progress_callback_user_data;

    whisper_encoder_begin_callback  encoder_begin_callback;
    void *                          encoder_begin_callback_user_data;

    whisper_abort_callback          abort_callback;
    void *                          abort_callback_user_data;

    whisper_logits_filter_callback  logits_filter_callback;
    void *                          logits_filter_callback_user_data;

    const whisper_grammar_element ** grammar_rules;
    size_t n_grammar_rules;
    size_t i_start_rule;
    float grammar_penalty;
};

// ---------------------------------------------------------------------------
// whisper_token_data — per-token timing and probability
// ---------------------------------------------------------------------------

struct whisper_token_data {
    whisper_token id;    // Token id
    whisper_token tid;   // Forced timestamp token id
    float p;             // Probability of the token
    float plog;          // Log probability of the token
    float pt;            // Probability of the timestamp token
    float ptsum;         // Sum of probabilities of all timestamp tokens
    int64_t t0;          // Start time of the token (in 10ms units)
    int64_t t1;          // End time of the token (in 10ms units)
    float vlen;          // Voice length of the token
};

// Placeholder for grammar element (opaque; we never construct one in Swift)
struct whisper_grammar_element;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Default context params with GPU enabled.
WHISPER_API struct whisper_context_params whisper_context_default_params(void);

/// Load a ggml model file.  Returns NULL on failure.
WHISPER_API struct whisper_context * whisper_init_from_file_with_params(
    const char * path_model,
    struct whisper_context_params params
);

/// Legacy loader (no params). Use _with_params instead.
WHISPER_API struct whisper_context * whisper_init_from_file(
    const char * path_model
);

/// Free context and all associated resources.
WHISPER_API void whisper_free(struct whisper_context * ctx);

// ---------------------------------------------------------------------------
// Inference
// ---------------------------------------------------------------------------

/// Returns default params for the given sampling strategy.
WHISPER_API struct whisper_full_params whisper_full_default_params(
    enum whisper_sampling_strategy strategy
);

/// Run the full transcription pipeline on `n_samples` Float32 PCM samples.
/// Returns 0 on success.
WHISPER_API int whisper_full(
    struct whisper_context * ctx,
    struct whisper_full_params params,
    const float * samples,
    int n_samples
);

// ---------------------------------------------------------------------------
// Result accessors (call after whisper_full returns 0)
// ---------------------------------------------------------------------------

/// Number of generated segments.
WHISPER_API int whisper_full_n_segments(struct whisper_context * ctx);

/// Segment start time in 10 ms units (multiply by 0.01 to get seconds).
WHISPER_API int64_t whisper_full_get_segment_t0(
    struct whisper_context * ctx,
    int i_segment
);

/// Segment end time in 10 ms units.
WHISPER_API int64_t whisper_full_get_segment_t1(
    struct whisper_context * ctx,
    int i_segment
);

/// Segment text (UTF-8). Valid until the next whisper_full call.
WHISPER_API const char * whisper_full_get_segment_text(
    struct whisper_context * ctx,
    int i_segment
);

/// Number of tokens in a segment.
WHISPER_API int whisper_full_n_tokens(
    struct whisper_context * ctx,
    int i_segment
);

/// Token-level data (id, probability, timestamps).
WHISPER_API struct whisper_token_data whisper_full_get_token_data(
    struct whisper_context * ctx,
    int i_segment,
    int i_token
);

/// Token probability (convenience wrapper around whisper_token_data.p).
WHISPER_API float whisper_full_get_token_p(
    struct whisper_context * ctx,
    int i_segment,
    int i_token
);

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

/// Returns the auto-detected language id for `i_segment` (call after
/// whisper_full with language="auto").
WHISPER_API int whisper_full_lang_id(struct whisper_context * ctx);

/// Converts a language id to a BCP-47 code string ("en", "fr", …).
WHISPER_API const char * whisper_lang_str(int id);

// ---------------------------------------------------------------------------
// System info
// ---------------------------------------------------------------------------

/// Returns a string describing compiled-in backends ("AVX AVX2 Metal …").
WHISPER_API const char * whisper_print_system_info(void);

#ifdef __cplusplus
}
#endif

#endif /* WHISPER_BRIDGE_H */
