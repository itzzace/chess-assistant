#import <Foundation/Foundation.h>

typedef struct MaiaResult {
    char move[8];
    double winPct;
    double whiteEval;
    bool ok;
    int stage;
    int legalCount;
} MaiaResult;

typedef void (^MaiaResultBlock)(MaiaResult res);

#ifdef __cplusplus
extern "C" {
#endif

bool MaiaLoad(const char *mlpackagePath);
bool MaiaAvailable(void);
void MaiaGo(const char *fen, int selfElo, int oppoElo, MaiaResultBlock done);

#ifdef __cplusplus
}
#endif
