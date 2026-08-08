#import "maia.h"
#import "engine.h"
#import <CoreML/CoreML.h>
#import <vector>
#import <string>
#import <unordered_map>
#import <algorithm>

static MLModel *gMaiaModel = nil;
static std::vector<std::string> gMoves;
static std::unordered_map<std::string, int> gMoveIdx;

static std::string squareName(int sq) {
    char s[3];
    s[0] = 'a' + (sq & 7);
    s[1] = '1' + (sq >> 3);
    s[2] = '\0';
    return std::string(s);
}

static void buildMoveTables(void) {
    if (!gMoves.empty()) return;
    gMoves.resize(4352);
    for (int from = 0; from < 64; from++)
        for (int to = 0; to < 64; to++)
            gMoves[from * 64 + to] = squareName(from) + squareName(to);
    int idx = 4096;
    const char *pieces = "qrbn";
    for (int ff = 0; ff < 8; ff++)
        for (int ft = 0; ft < 8; ft++)
            for (int p = 0; p < 4; p++) {
                char s[6];
                s[0] = 'a' + ff; s[1] = '7';
                s[2] = 'a' + ft; s[3] = '8';
                s[4] = pieces[p]; s[5] = '\0';
                gMoves[idx++] = std::string(s);
            }
    for (int i = 0; i < (int)gMoves.size(); i++)
        gMoveIdx[gMoves[i]] = i;
}

static std::string mirrorUci(const std::string &u) {
    std::string m = u;
    m[1] = '0' + (9 - (u[1] - '0'));
    m[3] = '0' + (9 - (u[3] - '0'));
    return m;
}

static bool parseFenBoard(const char *fen, char board[64], int *sideBlack) {
    for (int i = 0; i < 64; i++) board[i] = 0;
    const char *p = fen;
    int sq = 56;
    while (*p && *p != ' ') {
        char c = *p++;
        if (c == '/') { sq -= 16; }
        else if (c >= '1' && c <= '8') { sq += (c - '0'); }
        else {
            if (sq >= 0 && sq < 64) board[sq] = c;
            sq++;
        }
    }
    while (*p == ' ') p++;
    *sideBlack = (*p == 'b') ? 1 : 0;
    return true;
}

static int pieceType(char c) {
    switch (c) {
        case 'P': case 'p': return 1;
        case 'N': case 'n': return 2;
        case 'B': case 'b': return 3;
        case 'R': case 'r': return 4;
        case 'Q': case 'q': return 5;
        case 'K': case 'k': return 6;
    }
    return 0;
}

static MLMultiArray *buildTokens(const char *fen, int sideBlack) {
    char board[64];
    int sb = 0;
    parseFenBoard(fen, board, &sb);

    float base[64 * 12];
    for (int i = 0; i < 64 * 12; i++) base[i] = 0.0f;

    for (int sq = 0; sq < 64; sq++) {
        char c = board[sq];
        if (!c) continue;
        int t = pieceType(c);
        if (!t) continue;
        int isBlackPiece = (c >= 'a' && c <= 'z') ? 1 : 0;

        int tsq, tcolorBlack;
        if (sideBlack) {
            tsq = sq ^ 56;
            tcolorBlack = isBlackPiece ? 0 : 1;
        } else {
            tsq = sq;
            tcolorBlack = isBlackPiece;
        }
        int channel = (t - 1) + (tcolorBlack ? 6 : 0);
        base[tsq * 12 + channel] = 1.0f;
    }

    NSError *err = nil;
    MLMultiArray *arr = [[MLMultiArray alloc] initWithShape:@[@1, @64, @96]
                                                   dataType:MLMultiArrayDataTypeFloat32
                                                      error:&err];
    if (!arr) return nil;
    float *dst = (float *)arr.dataPointer;
    for (int sqi = 0; sqi < 64; sqi++)
        for (int f = 0; f < 8; f++)
            for (int ch = 0; ch < 12; ch++)
                dst[sqi * 96 + f * 12 + ch] = base[sqi * 12 + ch];
    return arr;
}

static MLMultiArray *scalarInt32(int v) {
    NSError *err = nil;
    MLMultiArray *a = [[MLMultiArray alloc] initWithShape:@[@1]
                                                 dataType:MLMultiArrayDataTypeInt32
                                                    error:&err];
    if (!a) return nil;
    ((int32_t *)a.dataPointer)[0] = (int32_t)v;
    return a;
}

extern "C" bool MaiaLoad(const char *mlpackagePath) {
    if (gMaiaModel) return true;
    buildMoveTables();

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:mlpackagePath];
        NSURL *url = [NSURL fileURLWithPath:path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return false;

        NSError *err = nil;
        NSURL *compiled = [MLModel compileModelAtURL:url error:&err];
        if (!compiled || err) return false;

        MLModelConfiguration *cfg = [[MLModelConfiguration alloc] init];
        cfg.computeUnits = MLComputeUnitsCPUOnly;
        MLModel *m = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&err];
        if (!m || err) return false;
        gMaiaModel = m;
    }
    return gMaiaModel != nil;
}

extern "C" bool MaiaAvailable(void) {
    return gMaiaModel != nil;
}

extern "C" void MaiaGo(const char *fen, int selfElo, int oppoElo, MaiaResultBlock done) {
    MaiaResult res;
    res.move[0] = '\0';
    res.winPct = 0;
    res.whiteEval = 0;
    res.ok = false;
    res.stage = 0;
    res.legalCount = 0;
    res.err[0] = '\0';

    if (!gMaiaModel) { res.stage = 1; if (done) done(res); return; }

    std::string fenStr(fen);
    int sideBlack = 0;
    {
        char b[64]; parseFenBoard(fen, b, &sideBlack);
    }

    char legalBuf[256 * 6];
    int legalCount = StockfishLegalMoves(fen, legalBuf, 256);
    res.legalCount = legalCount;
    if (legalCount <= 0) { res.stage = 2; if (done) done(res); return; }

    @autoreleasepool {
        MLMultiArray *tokens = buildTokens(fen, sideBlack);
        MLMultiArray *se = scalarInt32(selfElo);
        MLMultiArray *oe = scalarInt32(oppoElo);
        if (!tokens || !se || !oe) { res.stage = 3; if (done) done(res); return; }

        NSDictionary *feats = @{
            @"tokens": [MLFeatureValue featureValueWithMultiArray:tokens],
            @"self_elo": [MLFeatureValue featureValueWithMultiArray:se],
            @"oppo_elo": [MLFeatureValue featureValueWithMultiArray:oe],
        };
        NSError *err = nil;
        MLDictionaryFeatureProvider *prov =
            [[MLDictionaryFeatureProvider alloc] initWithDictionary:feats error:&err];
        if (!prov || err) { res.stage = 4; if (done) done(res); return; }

        id<MLFeatureProvider> out = [gMaiaModel predictionFromFeatures:prov error:&err];
        if (!out || err) {
            res.stage = 5;
            if (err) std::strncpy(res.err, [err.localizedDescription UTF8String], 191);
            if (done) done(res);
            return;
        }

        MLMultiArray *moveLogits = [out featureValueForName:@"move_logits"].multiArrayValue;
        MLMultiArray *valueLogits = [out featureValueForName:@"value_logits"].multiArrayValue;
        if (!moveLogits) { res.stage = 6; if (done) done(res); return; }

        struct Cand { double logit; std::string uci; };
        std::vector<Cand> cands;
        for (int i = 0; i < legalCount; i++) {
            std::string uci(&legalBuf[i * 6]);
            std::string modelUci = sideBlack ? mirrorUci(uci) : uci;
            auto it = gMoveIdx.find(modelUci);
            if (it == gMoveIdx.end()) continue;
            double v = [[moveLogits objectAtIndexedSubscript:it->second] doubleValue];
            cands.push_back({v, uci});
        }
        if (cands.empty()) { res.stage = 7; if (done) done(res); return; }

        std::sort(cands.begin(), cands.end(),
                  [](const Cand &a, const Cand &b) { return a.logit > b.logit; });

        double mx = cands[0].logit, sum = 0;
        for (auto &c : cands) sum += exp(c.logit - mx);

        int n = (int)cands.size(); if (n > 4) n = 4;
        res.count = n;
        for (int k = 0; k < n; k++) {
            std::strncpy(res.moves[k], cands[k].uci.c_str(), 7);
            res.moves[k][7] = '\0';
            res.policy[k] = exp(cands[k].logit - mx) / sum;
        }
        std::strncpy(res.move, cands[0].uci.c_str(), 7);
        res.move[7] = '\0';

        double stmScore = 0;
        if (valueLogits && valueLogits.count >= 3) {
            double l[3];
            l[0] = [[valueLogits objectAtIndexedSubscript:0] doubleValue];
            l[1] = [[valueLogits objectAtIndexedSubscript:1] doubleValue];
            l[2] = [[valueLogits objectAtIndexedSubscript:2] doubleValue];
            double mx = fmax(l[0], fmax(l[1], l[2]));
            double e0 = exp(l[0] - mx), e1 = exp(l[1] - mx), e2 = exp(l[2] - mx);
            double s = e0 + e1 + e2;
            double lossP = e0 / s, winP = e2 / s;
            res.winPct = winP * 100.0;
            stmScore = (winP - lossP) * 4.0;
        }
        res.whiteEval = sideBlack ? -stmScore : stmScore;
        res.stage = 100;
        res.ok = true;
    }

    if (done) done(res);
}
