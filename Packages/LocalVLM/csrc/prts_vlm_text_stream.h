#pragma once
#include "prts_local_vlm.h"

#include <string>

// Keep model control markers out of callbacks without consuming literal OCR punctuation.
// Token boundaries may split both the marker and a UTF-8 character.
class prts_vlm_text_stream {
  public:
    prts_vlm_text_stream(prts_vlm_text_fn on_text, void *user) : on_text(on_text), user(user) {}

    // Returns true once the known stray-turn marker completes.
    bool append(const char *piece, size_t count) {
        output.append(piece, count);
        const size_t stray = output.find(stop_marker);
        if (stray != std::string::npos) {
            output.resize(stray);
            publish(complete_end());
            return true;
        }
        size_t end = complete_end();
        // A prefix is not a control marker yet. Hold it until later tokens resolve it.
        for (size_t length = stop_marker.size() - 1; length > 0; length--) {
            if (length <= end - sent &&
                output.compare(end - length, length, stop_marker, 0, length) == 0) {
                end -= length;
                break;
            }
        }
        publish(end);
        return false;
    }

    // A successful end of turn makes an unfinished marker prefix ordinary text.
    void finish() {
        publish(complete_end());
    }

    const std::string &text() const {
        return output;
    }

  private:
    inline static const std::string stop_marker = "</think>";
    prts_vlm_text_fn on_text;
    void *user;
    std::string output;
    size_t sent = 0;

    size_t complete_end() const {
        size_t end = output.size(), back = 0;
        while (back < 4 && back < end - sent && (output[end - 1 - back] & 0xC0) == 0x80)
            back++;
        if (back < end - sent) {
            const unsigned char lead = output[end - 1 - back];
            const size_t need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
            if (need > back + 1)
                end -= back + 1;
        }
        return end;
    }

    void publish(size_t end) {
        if (end > sent) {
            if (on_text)
                on_text(user, output.data() + sent, end - sent);
            sent = end;
        }
    }
};
