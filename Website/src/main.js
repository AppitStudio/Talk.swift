import './style.css';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

const motion = gsap.matchMedia();

// Content remains readable without JavaScript. Motion is an enhancement and
// reverts immediately if the operating system's motion preference changes.
motion.add('(prefers-reduced-motion: no-preference)', () => {
  const introduction = gsap.timeline({ defaults: { ease: 'power3.out' } });
  introduction
    .from('.hero-copy', { y: 18, opacity: 0, duration: 0.75 })
    .from('.conversation', { y: 24, opacity: 0, duration: 0.8 }, 0.15)
    .from('.app-node', { y: 12, opacity: 0, stagger: 0.1, duration: 0.5 }, 0.4)
    .from('.request-line', { opacity: 0, x: -8, duration: 0.4 }, 0.9)
    .fromTo('.packet-outgoing', { x: 0, opacity: 0 }, { x: (_, target) => target.parentElement.clientWidth, opacity: 1, duration: 0.65, ease: 'power1.inOut' }, 1)
    .to('.packet-outgoing', { opacity: 0, duration: 0.15 }, 1.65)
    .fromTo('.packet-incoming', { x: (_, target) => target.parentElement.clientWidth, opacity: 0 }, { x: 0, opacity: 1, duration: 0.65, ease: 'power1.inOut' }, 1.8)
    .to('.packet-incoming', { opacity: 0, duration: 0.15 }, 2.45)
    .from('.response-line', { opacity: 0, x: 8, duration: 0.45 }, 2.15);

  // The single scroll sequence follows the actual order of pairing, without
  // pinning, scroll interception, looping, or moving the surrounding layout.
  gsap.from('.step-marker span', {
    scale: 0.75,
    opacity: 0,
    duration: 0.5,
    stagger: 0.28,
    ease: 'power2.out',
    scrollTrigger: {
      trigger: '.pairing-steps',
      start: 'top 75%',
      once: true,
    },
  });
});

if (import.meta.hot) {
  import.meta.hot.dispose(() => motion.revert());
}
