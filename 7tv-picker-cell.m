/*
 * 7tv-picker-cell.m
 * Extrait de SevenTVManager.m (nettoyage picker).
 */

#import "7tv-picker-cell.h"
#import "SevenTVEmoteAnimationEngine.h"
#import "SevenTVEmoteImageCache.h"

@implementation S7TVEmotePickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _emoteImageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        _emoteImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _emoteImageView.contentMode = UIViewContentModeScaleAspectFit;
        _emoteImageView.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:_emoteImageView];

        // Badge favori : petite pastille pleine (pas juste l'icône seule) à
        // cheval sur le coin supérieur droit de la cellule, façon "notif
        // badge" — plus lisible que l'étoile flottante de la V1 sur fond
        // carte arrondi.
        _favoriteStarView = [[UIImageView alloc] init];
        _favoriteStarView.backgroundColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:1.0];
        _favoriteStarView.layer.cornerRadius = 6;
        _favoriteStarView.clipsToBounds = YES;
        _favoriteStarView.contentMode = UIViewContentModeCenter;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:6 weight:UIImageSymbolWeightBold];
        _favoriteStarView.image = [[UIImage systemImageNamed:@"star.fill" withConfiguration:cfg]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _favoriteStarView.tintColor = [UIColor whiteColor];
        _favoriteStarView.hidden = YES;
        // Ajouté à `self` (pas à contentView) : contentView a clipsToBounds=YES
        // pour les coins arrondis, ce qui rognerait le badge qui doit déborder
        // légèrement au-dessus du coin de la cellule.
        [self addSubview:_favoriteStarView];

        self.clipsToBounds = NO; // le badge favori déborde légèrement du coin
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 8;
        CGFloat onePixel = 1.0 / [UIScreen mainScreen].scale;
        self.contentView.layer.borderWidth = onePixel;
        self.contentView.layer.borderColor = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0].CGColor; // #2A2A2E
        self.contentView.backgroundColor = [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C — carte, un cran au-dessus du fond de grille
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize cs = self.bounds.size;
    self.favoriteStarView.frame = CGRectMake(cs.width - 9, -3, 12, 12);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.animationFrameRequest cancel];
    self.animationFrameRequest = nil;
    self.imageLoadGeneration += 1;
    self.animationGeneration += 1;
    self.wantsAnimation = NO;
    self.emoteImageView.image = nil;
    self.favoriteStarView.hidden = YES;
    self.currentEmoteKey = nil;
    // Se retire de l'engine d'animation : sans ça, une cellule recyclée pour
    // une AUTRE emote continuerait de recevoir les redraws de l'ancienne
    // (l'engine ne sait pas qu'elle a changé de contenu tant qu'on ne le lui
    // dit pas explicitement).
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:self];
}

@end
