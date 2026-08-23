#ifndef SINGULARITY_SURFACE_EFFECT_H
#define SINGULARITY_SURFACE_EFFECT_H

#include <gtk/gtk.h>
#include <stdint.h>

void singularity_surface_effect_set(GtkWidget *widget, uint32_t mode,
	int x, int y, int width, int height, uint32_t strength);

#endif
