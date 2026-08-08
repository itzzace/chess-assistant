#import <Foundation/Foundation.h>

typedef struct EngineLine {
    char move[8];
    bool hasScore;
    bool isMate;
    int  score;
} EngineLine;

typedef void (^EngineResultBlock)(const EngineLine *lines, int count);

#ifdef __cplusplus
extern "C" {
#endif

void EngineStart(void);

void EngineGo(const char *fen, int depth, int elo, int multipv, EngineResultBlock done);

#ifdef __cplusplus
}
#endif
