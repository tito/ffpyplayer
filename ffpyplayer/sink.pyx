#cython: cdivision=True

include "ff_defs_comp.pxi"
include "inline_funcs.pxi"

from cpython.ref cimport PyObject

cdef extern from "Python.h":
    PyObject* PyString_FromString(const char *)
    void Py_DECREF(PyObject *)

from ffpyplayer.ffthreading cimport MTMutex


cdef bytes sub_ass = b'ass', sub_text = b'text', sub_fmt

cdef void raise_py_exception(bytes msg) nogil except *:
    with gil:
        raise Exception(msg)


cdef class VideoSink(object):

    def __cinit__(VideoSink self, MTMutex mutex=None, object callback=None,
                  **kwargs):
        self.alloc_mutex = mutex
        self.callback = callback
        self.requested_alloc = 0
        self.pix_fmt = AV_PIX_FMT_NONE

    cdef AVPixelFormat _get_out_pix_fmt(VideoSink self) nogil:
        return self.pix_fmt

    cdef object get_out_pix_fmt(VideoSink self):
        return av_get_pix_fmt_name(self.pix_fmt)

    cdef void set_out_pix_fmt(VideoSink self, AVPixelFormat out_fmt):
        '''
        Users set the pixel fmt here. If avfilter is enabled, the filter is
        changed when this is changed. If disabled, this method may only
        be called before other methods below, and can not be called once things
        are running.

        After the user changes the pix_fmt, it might take a few frames until they
        receive the new fmt in case pics were already queued.
        '''
        self.pix_fmt = out_fmt

    cdef int request_thread(VideoSink self, uint8_t request) nogil except 1:
        if request == FF_ALLOC_EVENT:
            self.alloc_mutex.lock()
            self.requested_alloc = 1
            self.alloc_mutex.unlock()
        else:
            self.request_thread_py(request)
        return 0

    cdef int request_thread_py(VideoSink self, uint8_t request) nogil except 1:
        if request == FF_QUIT_EVENT:
            with gil:
                self.callback()('quit', '')
        elif request == FF_EOF_EVENT:
            with gil:
                self.callback()('eof', '')
        return 0

    cdef int peep_alloc(VideoSink self) nogil except 1:
        self.alloc_mutex.lock()
        self.requested_alloc = 0
        self.alloc_mutex.unlock()
        return 0

    cdef int alloc_picture(VideoSink self, VideoPicture *vp) nogil except 1:
        if vp.pict != NULL:
            self.free_alloc(vp)
        vp.pict = av_frame_alloc()
        vp.pict_ref = av_frame_alloc()
        if vp.pict == NULL or vp.pict_ref == NULL:
            av_log(NULL, AV_LOG_FATAL, "Could not allocate avframe of size %dx%d.\n", vp.width, vp.height)
            raise_py_exception(b'Could not allocate avframe.')
        if (av_image_alloc(vp.pict.data, vp.pict.linesize, vp.width,
                           vp.height, vp.pix_fmt, 1) < 0):
            av_log(NULL, AV_LOG_FATAL, "Could not allocate avframe buffer.\n")
            raise_py_exception(b'Could not allocate avframe buffer')
        vp.pict.width = vp.width
        vp.pict.height = vp.height
        vp.pict.format = <int>vp.pix_fmt
        return 0

    cdef void free_alloc(VideoSink self, VideoPicture *vp) nogil:
        if vp.pict != NULL:
            av_freep(&vp.pict.data[0])
            av_frame_free(&vp.pict)
            vp.pict = NULL
        if vp.pict_ref != NULL:
            av_frame_free(&vp.pict_ref)
            vp.pict_ref = NULL

    cdef int copy_picture(VideoSink self, VideoPicture *vp, AVFrame *src_frame,
                           VideoSettings *player) nogil except 1:

        IF CONFIG_AVFILTER:
            av_frame_unref(vp.pict_ref)
            av_frame_move_ref(vp.pict_ref, src_frame)
        ELSE:
            if vp.pix_fmt == <AVPixelFormat>src_frame.format:
                av_frame_unref(vp.pict_ref)
                av_frame_move_ref(vp.pict_ref, src_frame)
                return 0
            av_opt_get_int(player.sws_opts, 'sws_flags', 0, &player.sws_flags)
            player.img_convert_ctx = sws_getCachedContext(player.img_convert_ctx,\
            vp.width, vp.height, <AVPixelFormat>src_frame.format, vp.width, vp.height,\
            vp.pix_fmt, player.sws_flags, NULL, NULL, NULL)
            if player.img_convert_ctx == NULL:
                av_log(NULL, AV_LOG_FATAL, "Cannot initialize the conversion context\n")
                raise_py_exception(b'Cannot initialize the conversion context.')
            sws_scale(player.img_convert_ctx, src_frame.data, src_frame.linesize,
                      0, vp.height, vp.pict.data, vp.pict.linesize)
            av_frame_unref(src_frame)
        return 0

    cdef int subtitle_display(VideoSink self, AVSubtitle *sub) nogil except 1:
        cdef PyObject *buff
        cdef int i
        cdef double pts
        with gil:
            for i in range(sub.num_rects):
                if sub.rects[i].type == SUBTITLE_ASS:
                    buff = PyString_FromString(sub.rects[i].ass)
                    sub_fmt = sub_ass
                elif sub.rects[i].type == SUBTITLE_TEXT:
                    buff = PyString_FromString(sub.rects[i].text)
                    sub_fmt = sub_text
                else:
                    buff = NULL
                    continue
                if sub.pts != AV_NOPTS_VALUE:
                    pts = sub.pts / <double>AV_TIME_BASE
                else:
                    pts = 0.0
                self.callback()('display_sub', (<object>buff, sub_fmt, pts,
                                                sub.start_display_time / 1000.,
                                                sub.end_display_time / 1000.))
                if buff != NULL:
                    Py_DECREF(buff)
        return 0
