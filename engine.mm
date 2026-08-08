#import "engine.h"

#include <string>
#include <deque>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <thread>
#include <iostream>
#include <sstream>
#include <cstring>

#include "bitboard.h"
#include "endgame.h"
#include "evaluate.h"
#include "misc.h"
#include "position.h"
#include "psqt.h"
#include "search.h"
#include "thread.h"
#include "tt.h"
#include "uci.h"

using namespace Stockfish;

namespace {

class InBuf : public std::streambuf {
    std::mutex m;
    std::condition_variable cv;
    std::deque<std::string> q;
    std::string cur;
    size_t pos = 0;
protected:
    int underflow() override {
        std::unique_lock<std::mutex> lk(m);
        while (pos >= cur.size()) {
            while (q.empty()) cv.wait(lk);
            cur = q.front(); q.pop_front(); pos = 0;
        }
        return traits_type::to_int_type(cur[pos]);
    }
    int uflow() override {
        int c = underflow();
        if (c != traits_type::eof()) pos++;
        return c;
    }
public:
    void push(const std::string &s) {
        std::lock_guard<std::mutex> lk(m);
        q.push_back(s);
        cv.notify_one();
    }
};

class OutBuf : public std::streambuf {
    std::mutex m;
    std::string line;
    std::function<void(const std::string &)> onLine;
protected:
    int overflow(int c) override {
        if (c == traits_type::eof()) return c;
        std::string done;
        bool flush = false;
        {
            std::lock_guard<std::mutex> lk(m);
            if (c == '\n') { done.swap(line); flush = true; }
            else line.push_back((char)c);
        }
        if (flush) onLine(done);
        return c;
    }
    std::streamsize xsputn(const char *s, std::streamsize n) override {
        for (std::streamsize i = 0; i < n; i++) overflow((unsigned char)s[i]);
        return n;
    }
public:
    void setHandler(std::function<void(const std::string &)> h) { onLine = std::move(h); }
};

InBuf  gIn;
OutBuf gOut;

#define MAXPV 4
struct Cand { std::string move; bool hasScore = false; bool isMate = false; int score = 0; bool filled = false; };

struct Req { std::string fen; int depth; int elo; int multipv; EngineResultBlock cb; };

std::mutex        gReqMutex;
std::deque<Req>   gQueue;
bool              gBusy = false;
EngineResultBlock gPending = nil;
Cand              gCand[MAXPV + 1];
int               gWantPV = 1;

int    gCurElo    = -1;
int    gCurPV     = -1;

void resetCands() {
    for (int i = 0; i <= MAXPV; i++) gCand[i] = Cand();
}

void applyOptions(int elo, int multipv) {
    if (elo != gCurElo) {
        gCurElo = elo;
        if (elo >= 3190) {
            gIn.push("setoption name UCI_LimitStrength value false\n");
            gIn.push("setoption name Skill Level value 20\n");
        } else if (elo >= 1320) {
            gIn.push("setoption name Skill Level value 20\n");
            gIn.push("setoption name UCI_LimitStrength value true\n");
            gIn.push(std::string("setoption name UCI_Elo value ") + std::to_string(elo) + "\n");
        } else {
            int skill = (elo - 400) * 8 / 919;
            if (skill < 0) skill = 0; if (skill > 8) skill = 8;
            gIn.push("setoption name UCI_LimitStrength value false\n");
            gIn.push(std::string("setoption name Skill Level value ") + std::to_string(skill) + "\n");
        }
    }
    if (multipv != gCurPV) {
        gCurPV = multipv;
        gIn.push(std::string("setoption name MultiPV value ") + std::to_string(multipv) + "\n");
    }
}

void startNext_locked() {
    if (gBusy || gQueue.empty()) return;
    Req r = gQueue.front(); gQueue.pop_front();
    gBusy = true;
    gPending = r.cb;
    gWantPV = r.multipv;
    resetCands();
    applyOptions(r.elo, r.multipv);
    gIn.push(std::string("position fen ") + r.fen + "\n");
    gIn.push(std::string("go depth ") + std::to_string(r.depth) + "\n");
}

void handleLine(const std::string &ln) {

    if (ln.compare(0, 5, "info ") == 0) {
        size_t pvp = ln.find(" pv ");
        if (pvp == std::string::npos) return;
        int idx = 1;
        size_t mp = ln.find(" multipv ");
        if (mp != std::string::npos) { std::istringstream is(ln.substr(mp + 9)); is >> idx; }
        if (idx < 1 || idx > MAXPV) return;

        std::string firstMove;
        { std::istringstream is(ln.substr(pvp + 4)); is >> firstMove; }
        if (firstMove.empty()) return;

        Cand &c = gCand[idx];
        c.move = firstMove; c.filled = true;
        size_t sp = ln.find(" score ");
        if (sp != std::string::npos) {
            std::istringstream is(ln.substr(sp + 7));
            std::string kind; int val = 0;
            if (is >> kind >> val) {
                if (kind == "cp")   { c.hasScore = true; c.isMate = false; c.score = val; }
                else if (kind == "mate") { c.hasScore = true; c.isMate = true; c.score = val; }
            }
        }
        return;
    }

    if (ln.compare(0, 9, "bestmove ") == 0) {
        std::string bm;
        { std::istringstream is(ln.substr(9)); is >> bm; }

        EngineResultBlock cb = nil;
        EngineLine out[MAXPV];
        int count = 0;
        {
            std::lock_guard<std::mutex> lk(gReqMutex);
            cb = gPending; gPending = nil;
            gBusy = false;
            for (int i = 1; i <= gWantPV && i <= MAXPV; i++) {
                if (!gCand[i].filled) break;
                EngineLine &l = out[count];
                strncpy(l.move, gCand[i].move.c_str(), sizeof(l.move) - 1);
                l.move[sizeof(l.move) - 1] = '\0';
                l.hasScore = gCand[i].hasScore; l.isMate = gCand[i].isMate; l.score = gCand[i].score;
                count++;
            }

            if (count == 0) {
                EngineLine &l = out[0];
                strncpy(l.move, bm.c_str(), sizeof(l.move) - 1);
                l.move[sizeof(l.move) - 1] = '\0';
                l.hasScore = false; l.isMate = false; l.score = 0;
                count = 1;
            }
            startNext_locked();
        }
        if (cb) cb(out, count);
    }
}

void engineThread() {
    static char arg0[] = "stockfish";
    char *argv[] = { arg0, nullptr };

    CommandLine::init(1, argv);
    UCI::init(Options);
    Tune::init();
    PSQT::init();
    Bitboards::init();
    Position::init();
    Bitbases::init();
    Endgames::init();
    Threads.set(size_t(Options["Threads"]));
    Search::clear();
    Eval::NNUE::init();

    gOut.setHandler(handleLine);
    std::cin.rdbuf(&gIn);
    std::cout.rdbuf(&gOut);

    UCI::loop(1, argv);
}

}

extern "C" void EngineStart(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        std::thread(engineThread).detach();
    });
}

extern "C" void EngineGo(const char *fen, int depth, int elo, int multipv, EngineResultBlock done) {
    EngineStart();
    if (multipv < 1) multipv = 1; if (multipv > MAXPV) multipv = MAXPV;

    std::lock_guard<std::mutex> lk(gReqMutex);

    while (gQueue.size() >= 4) gQueue.pop_front();
    gQueue.push_back(Req{ std::string(fen), depth, elo, multipv, [done copy] });
    startNext_locked();
}
