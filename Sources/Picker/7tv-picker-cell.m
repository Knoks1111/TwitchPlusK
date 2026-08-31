/*
 * 7tv-picker-cell.m
 * Extrait de 7tv-core-manager.m (nettoyage picker).
 */

#import "Picker/7tv-picker-cell.h"
#import "Emote/7tv-emote-animation-engine.h"
#import "Emote/7tv-emote-image-cache.h"
#import "UI/7tv-oled-mode.h"

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

        _providerBadgeLabel = [[UILabel alloc] init];
        _providerBadgeLabel.font = [UIFont systemFontOfSize:7.0 weight:UIFontWeightBold];
        _providerBadgeLabel.textAlignment = NSTextAlignmentCenter;
        _providerBadgeLabel.textColor = UIColor.whiteColor;
        _providerBadgeLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
        _providerBadgeLabel.layer.cornerRadius = 3.0;
        _providerBadgeLabel.clipsToBounds = YES;
        _providerBadgeLabel.hidden = YES;
        [self addSubview:_providerBadgeLabel];

        self.clipsToBounds = NO; // le badge favori déborde légèrement du coin
        self.contentView.clipsToBounds = YES;
        self.contentView.layer.cornerRadius = 8;
        CGFloat onePixel = 1.0 / [UIScreen mainScreen].scale;
        self.contentView.layer.borderWidth = onePixel;
        self.backgroundColor = [UIColor clearColor];
        [self s7tv_applyOLEDColors];
    }
    return self;
}

- (void)s7tv_applyOLEDColors {
    BOOL oled = S7TVOLEDModeEnabled();
    // OLED : carte quasi noire (un cran à peine au-dessus du fond pur) et
    // bordure plus discrète — même langage que les capsules du picker.
    UIColor *cardColor = oled
        ? [UIColor colorWithWhite:0.05 alpha:1.0]
        : [UIColor colorWithRed:0.098 green:0.098 blue:0.110 alpha:1.0]; // #19191C
    UIColor *borderColor = oled
        ? [UIColor colorWithWhite:0.12 alpha:1.0]
        : [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0]; // #2A2A2E
    self.contentView.backgroundColor = cardColor;
    self.contentView.layer.borderColor = borderColor.CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize cs = self.bounds.size;
    self.favoriteStarView.frame = CGRectMake(cs.width - 9, -3, 12, 12);
    self.providerBadgeLabel.frame = CGRectMake(2, cs.height - 12, 24, 10);
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
    self.providerBadgeLabel.hidden = YES;
    self.providerBadgeLabel.text = nil;
    self.currentEmoteKey = nil;
    // Se retire de l'engine d'animation : sans ça, une cellule recyclée pour
    // une AUTRE emote continuerait de recevoir les redraws de l'ancienne
    // (l'engine ne sait pas qu'elle a changé de contenu tant qu'on ne le lui
    // dit pas explicitement).
    [[SevenTVEmoteAnimationEngine sharedEngine] removeObserver:self];
}

@end
